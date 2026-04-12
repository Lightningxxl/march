defmodule March.Tracker.Item do
  @moduledoc """
  Normalized tracker item representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :task_key,
    :title,
    :description,
    :body,
    :task_kind,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :tasklist_guid,
    :task_section_guid,
    :task_section_guids_by_name,
    :task_custom_field_guids,
    :task_kind_option_guids,
    :task_status,
    :extra,
    :current_plan,
    :builder_workpad,
    :auditor_verdict,
    :pr_url,
    :comments,
    :tracker_payload,
    :fetched_at,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          task_key: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          body: String.t() | nil,
          task_kind: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          tasklist_guid: String.t() | nil,
          task_section_guid: String.t() | nil,
          task_section_guids_by_name: %{optional(String.t()) => String.t()} | nil,
          task_custom_field_guids: %{optional(String.t()) => String.t()} | nil,
          task_kind_option_guids: %{optional(String.t()) => String.t()} | nil,
          task_status: String.t() | nil,
          extra: String.t() | nil,
          current_plan: String.t() | nil,
          builder_workpad: String.t() | nil,
          auditor_verdict: String.t() | nil,
          pr_url: String.t() | nil,
          comments: [map()] | nil,
          tracker_payload: map() | nil,
          fetched_at: DateTime.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
