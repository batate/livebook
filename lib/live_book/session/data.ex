defmodule LiveBook.Session.Data do
  @moduledoc false

  # A structure with shared session data.
  #
  # In some sense this structure is a `Notebook` decorated
  # with all the emphemeral session data.
  #
  # The data is kept both in the `Session` process and all the client processes.
  # All changes go to the `Session` process first to introduce linearity
  # and then are broadcasted to the clients, hence every client
  # receives changes in the same order.
  # Upon receiving a change message, every process applies
  # the change to the locally stored `Data`. In this way the local `Data`
  # stays the same in all processes, while the messages are minimal.

  defstruct [
    :notebook,
    :path,
    :section_infos,
    :cell_infos,
    :deleted_sections,
    :deleted_cells
  ]

  alias LiveBook.{Notebook, Evaluator}
  alias LiveBook.Notebook.{Cell, Section}

  @type t :: %__MODULE__{
          notebook: Notebook.t(),
          path: nil | String.t(),
          section_infos: %{Section.id() => section_info()},
          cell_infos: %{Cell.id() => cell_info()},
          deleted_sections: list(Section.t()),
          deleted_cells: list(Cell.t())
        }

  @type section_info :: %{
          evaluating_cell_id: Cell.id(),
          evaluation_queue: list(Cell.id())
        }

  @type cell_info :: %{
          status: cell_status(),
          revision: non_neg_integer(),
          # TODO: specify it's a list of deltas, once defined
          deltas: list(),
          evaluated_at: DateTime.t()
        }

  @type cell_status :: :fresh | :queued | :evaluating | :evaluated | :stale

  @type index :: non_neg_integer()

  @type operation ::
          {:insert_section, index(), Section.id()}
          | {:insert_cell, Section.id(), index(), Cell.type(), Cell.id()}
          | {:delete_section, Section.id()}
          | {:delete_cell, Cell.id()}
          | {:queue_cell_evaluation, Cell.id()}
          | {:add_cell_evaluation_stdout, Cell.id(), String.t()}
          | {:add_cell_evaluation_response, Cell.id(), Evaluator.evaluation_response()}
          | {:cancel_cell_evaluation, Cell.id()}

  @type action ::
          {:start_evaluation, Cell.t(), Section.t()}
          | {:stop_evaluation, Section.t()}
          | {:forget_evaluation, Cell.t(), Section.t()}

  @doc """
  Returns a fresh notebook session state.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      notebook: Notebook.new(),
      path: nil,
      section_infos: %{},
      cell_infos: %{},
      deleted_sections: [],
      deleted_cells: []
    }
  end

  @doc """
  Applies the change specified by `operation` to the given session `data`.

  All operations are reproducible (i.e. this function is pure),
  so provided all processes have the same session data
  they can individually apply any given operation and end up in the same state.

  An operation only applies changes to the structure, but it doesn't trigger
  any actual processing. It's the responsibility of the session process to ensure
  the system reflects the new structure. For instance, when a new cell is marked
  as evaluating, the session process should take care of triggering actual evaluation.

  Returns `{:ok, data, actions}` if the operation is valid, where `data` is the result
  of applying said operation to the given data, and `actions` is a list
  of side effects that should be performed for the new data to hold true.

  Returns `:error` if the operation is not valid. The `:error` is generally
  expected given the collaborative nature of sessions. For example if there are
  simultaneous deletion and evaluation operations on the same cell, we may perform delete first,
  in which case the evaluation is no longer valid (there's no cell with the given id).
  By returning `:error` we simply notify the caller that no changes were applied,
  so any related actions can be ignored.
  """
  @spec apply_operation(t(), operation()) :: {:ok, t(), list(action())} | :error
  def apply_operation(data, operation)

  def apply_operation(data, {:insert_section, index, id}) do
    section = %{Section.new() | id: id}

    data
    |> with_actions()
    |> insert_section(index, section)
    |> wrap_ok()
  end

  def apply_operation(data, {:insert_cell, section_id, index, type, id}) do
    with {:ok, _section} <- Notebook.fetch_section(data.notebook, section_id) do
      cell = %{Cell.new(type) | id: id}

      data
      |> with_actions()
      |> insert_cell(section_id, index, cell)
      |> wrap_ok()
    end
  end

  def apply_operation(data, {:delete_section, id}) do
    with {:ok, section} <- Notebook.fetch_section(data.notebook, id) do
      data
      |> with_actions()
      |> delete_section(section)
      |> wrap_ok()
    end
  end

  def apply_operation(data, {:delete_cell, id}) do
    with {:ok, cell, section} <- Notebook.fetch_cell_and_section(data.notebook, id) do
      case data.cell_infos[cell.id].status do
        :evaluating ->
          data
          |> with_actions()
          |> clear_section_evaluation(section)

        :queued ->
          data
          |> with_actions()
          |> unqueue_cell_evaluation(cell, section)
          |> unqueue_dependent_cells_evaluation(cell, section)
          |> mark_dependent_cells_as_stale(cell)

        _ ->
          data
          |> with_actions()
          |> mark_dependent_cells_as_stale(cell)
      end
      |> delete_cell(cell)
      |> add_action({:forget_evaluation, cell, section})
      |> wrap_ok()
    end
  end

  def apply_operation(data, {:queue_cell_evaluation, id}) do
    with {:ok, cell, section} <- Notebook.fetch_cell_and_section(data.notebook, id),
         :elixir <- cell.type,
         false <- data.cell_infos[cell.id].status in [:queued, :evaluating] do
      data
      |> with_actions()
      |> queue_prerequisite_cells_evaluation(cell, section)
      |> queue_cell_evaluation(cell, section)
      |> maybe_evaluate_queued()
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(data, {:add_cell_evaluation_stdout, id, string}) do
    with {:ok, cell, _} <- Notebook.fetch_cell_and_section(data.notebook, id) do
      data
      |> with_actions()
      |> add_cell_evaluation_stdout(cell, string)
      |> wrap_ok()
    end
  end

  def apply_operation(data, {:add_cell_evaluation_response, id, response}) do
    with {:ok, cell, section} <- Notebook.fetch_cell_and_section(data.notebook, id) do
      data
      |> with_actions()
      |> add_cell_evaluation_response(cell, response)
      |> finish_cell_evaluation(cell, section)
      |> mark_dependent_cells_as_stale(cell)
      |> maybe_evaluate_queued()
      |> wrap_ok()
    end
  end

  def apply_operation(data, {:cancel_cell_evaluation, id}) do
    with {:ok, cell, section} <- Notebook.fetch_cell_and_section(data.notebook, id) do
      case data.cell_infos[cell.id].status do
        :evaluating ->
          data
          |> with_actions()
          |> clear_section_evaluation(section)
          |> wrap_ok()

        :queued ->
          data
          |> with_actions()
          |> unqueue_cell_evaluation(cell, section)
          |> unqueue_dependent_cells_evaluation(cell, section)
          |> mark_dependent_cells_as_stale(cell)
          |> wrap_ok()

        _ ->
          :error
      end
    end
  end

  # ===

  defp with_actions(data, actions \\ []), do: {data, actions}

  defp wrap_ok({data, actions}), do: {:ok, data, actions}

  defp insert_section({data, _} = data_actions, index, section) do
    data_actions
    |> set!(
      notebook: Notebook.insert_section(data.notebook, index, section),
      section_infos: Map.put(data.section_infos, section.id, new_section_info())
    )
  end

  defp insert_cell({data, _} = data_actions, section_id, index, cell) do
    data_actions
    |> set!(
      notebook: Notebook.insert_cell(data.notebook, section_id, index, cell),
      cell_infos: Map.put(data.cell_infos, cell.id, new_cell_info())
    )
  end

  defp delete_section({data, _} = data_actions, section) do
    data_actions
    |> set!(
      notebook: Notebook.delete_section(data.notebook, section.id),
      section_infos: Map.delete(data.section_infos, section.id),
      deleted_sections: [section | data.deleted_sections]
    )
    |> reduce(section.cells, &delete_cell_info/2)
  end

  defp delete_cell({data, _} = data_actions, cell) do
    data_actions
    |> set!(
      notebook: Notebook.delete_cell(data.notebook, cell.id),
      deleted_cells: [cell | data.deleted_cells]
    )
    |> delete_cell_info(cell)
  end

  defp delete_cell_info({data, _} = data_actions, cell) do
    data_actions
    |> set!(cell_infos: Map.delete(data.cell_infos, cell.id))
  end

  defp queue_cell_evaluation(data_actions, cell, section) do
    data_actions
    |> update_section_info!(section.id, fn section ->
      %{section | evaluation_queue: section.evaluation_queue ++ [cell.id]}
    end)
    |> set_cell_info!(cell.id, status: :queued)
  end

  defp unqueue_cell_evaluation(data_actions, cell, section) do
    data_actions
    |> update_section_info!(section.id, fn section ->
      %{section | evaluation_queue: List.delete(section.evaluation_queue, cell.id)}
    end)
    |> set_cell_info!(cell.id, status: :stale)
  end

  defp add_cell_evaluation_stdout({data, _} = data_actions, _cell, _string) do
    data_actions
    |> set!(
      # TODO: add stdout to cell outputs
      notebook: data.notebook
    )
  end

  defp add_cell_evaluation_response({data, _} = data_actions, _cell, _response) do
    data_actions
    |> set!(
      # TODO: add result to outputs
      notebook: data.notebook
    )
  end

  defp finish_cell_evaluation(data_actions, cell, section) do
    data_actions
    |> set_cell_info!(cell.id, status: :evaluated, evaluated_at: DateTime.utc_now())
    |> set_section_info!(section.id, evaluating_cell_id: nil)
  end

  defp mark_dependent_cells_as_stale({data, _} = data_actions, cell) do
    invalidated_cells = child_cells_with_status(data, cell, :evaluated)

    data_actions
    |> reduce(invalidated_cells, &set_cell_info!(&1, &2.id, status: :stale))
  end

  defp fresh_parent_cells_queue(data, cell) do
    data.notebook
    |> Notebook.parent_cells(cell.id)
    |> Enum.take_while(fn parent -> data.cell_infos[parent.id].status == :fresh end)
    |> Enum.reverse()
  end

  defp child_cells_with_status(data, cell, status) do
    data.notebook
    |> Notebook.child_cells(cell.id)
    |> Enum.filter(fn cell -> data.cell_infos[cell.id].status == status end)
  end

  # If there are idle sections with non-empty evaluation queue,
  # the next queued cell for evaluation.
  defp maybe_evaluate_queued({data, _} = data_actions) do
    Enum.reduce(data.notebook.sections, data_actions, fn section, data_actions ->
      {data, _} = data_actions

      case data.section_infos[section.id] do
        %{evaluating_cell_id: nil, evaluation_queue: [id | ids]} ->
          cell = Enum.find(section.cells, &(&1.id == id))

          data_actions
          |> set!(notebook: Notebook.update_cell(data.notebook, id, &%{&1 | outputs: []}))
          |> set_cell_info!(id, status: :evaluating)
          |> set_section_info!(section.id, evaluating_cell_id: id, evaluation_queue: ids)
          |> add_action({:start_evaluation, cell, section})

        _ ->
          data_actions
      end
    end)
  end

  defp clear_section_evaluation(data_actions, section) do
    data_actions
    |> set_section_info!(section.id, evaluating_cell_id: nil, evaluation_queue: [])
    |> reduce(section.cells, &set_cell_info!(&1, &2.id, status: :fresh))
    |> add_action({:stop_evaluation, section})
  end

  defp queue_prerequisite_cells_evaluation({data, _} = data_actions, cell, section) do
    prerequisites_queue = fresh_parent_cells_queue(data, cell)

    data_actions
    |> reduce(prerequisites_queue, &queue_cell_evaluation(&1, &2, section))
  end

  defp unqueue_dependent_cells_evaluation({data, _} = data_actions, cell, section) do
    queued_dependent_cells = child_cells_with_status(data, cell, :queued)

    data_actions
    |> reduce(queued_dependent_cells, &unqueue_cell_evaluation(&1, &2, section))
  end

  defp add_action({data, actions}, action) do
    {data, actions ++ [action]}
  end

  defp new_section_info() do
    %{
      evaluating_cell_id: nil,
      evaluation_queue: []
    }
  end

  defp new_cell_info() do
    %{
      revision: 0,
      deltas: [],
      status: :fresh,
      evaluated_at: nil
    }
  end

  defp set!({data, actions}, changes) do
    Enum.reduce(changes, data, fn {key, value}, info ->
      Map.replace!(info, key, value)
    end)
    |> with_actions(actions)
  end

  defp set_cell_info!(data_actions, cell_id, changes) do
    update_cell_info!(data_actions, cell_id, fn info ->
      Enum.reduce(changes, info, fn {key, value}, info ->
        Map.replace!(info, key, value)
      end)
    end)
  end

  defp update_cell_info!({data, _} = data_actions, cell_id, fun) do
    cell_infos = Map.update!(data.cell_infos, cell_id, fun)
    set!(data_actions, cell_infos: cell_infos)
  end

  defp set_section_info!(data_actions, section_id, changes) do
    update_section_info!(data_actions, section_id, fn info ->
      Enum.reduce(changes, info, fn {key, value}, info ->
        Map.replace!(info, key, value)
      end)
    end)
  end

  defp update_section_info!({data, _} = data_actions, section_id, fun) do
    section_infos = Map.update!(data.section_infos, section_id, fun)
    set!(data_actions, section_infos: section_infos)
  end

  defp reduce(data_actions, list, reducer) do
    Enum.reduce(list, data_actions, fn elem, data_actions -> reducer.(data_actions, elem) end)
  end

  @doc """
  Finds the cell that's currently being evaluated in the given section.
  """
  @spec get_evaluating_cell_id(t(), Section.id()) :: Cell.id() | nil
  def get_evaluating_cell_id(data, section_id) do
    info = data.section_infos[section_id]
    info && info.evaluating_cell_id
  end
end