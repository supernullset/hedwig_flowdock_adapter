defmodule Hedwig.Adapters.Flowdock do
  use Hedwig.Adapter

  require Logger
  alias Hedwig.Adapters.Flowdock.ConnectionSupervisor, as: CS
  alias Hedwig.Adapters.Flowdock.RestConnection, as: RC

  defmodule State do
    defstruct user_id: nil,
      opts: nil,
      robot: nil
  end

  def init({robot, opts}) do
    Logger.info "Booting up..."

    opts
    |> Keyword.put(:adapter_pid, self())
    |> CS.start_link()

    Kernel.send(self(), :connection_ready)

    {:ok, %State{opts: opts,
                 robot: robot,
                 user_id: Enum.find(RC.users, fn u -> u["nick"] == opts[:name] end)["id"]}}
  end

  def robot_name(pid) do
    GenServer.call(pid, {:robot_name})
  end

  def accept_message(pid, msg, flow, user, thread) do
    GenServer.cast(pid, {:message, msg, flow, user, thread})
  end

  def handle_cast({:send, msg}, state) do
    msg
    |> flowdock_message
    |> RC.send_message

    {:noreply, state}
  end

  def handle_cast({:send_raw, msg}, state) do
    msg
    |> RC.send_message

    {:noreply, state}
  end

  def handle_cast({:reply, %{user: user, text: text} = msg}, state) do
    %{msg | text: "@#{user.name}: #{text}"}
    |> flowdock_message
    |> RC.send_message

    {:noreply, state}
  end

  def handle_cast({:emote, %{text: text, user: user} = msg}, state) do
    %{msg | text: "@#{user.name}: #{text}"}
    |> flowdock_message
    |> RC.send_message

    {:noreply, state}
  end

  def handle_cast({:message, content, flow_id, user, thread_id}, %{robot: robot} = state) do
    msg = %Hedwig.Message{
      ref: make_ref(),
      room: flow_id,
      private: %{
        thread_id: thread_id
      },
      robot: robot,
      text: content,
      type: "message",
      user: %Hedwig.User{
        id: user,
        name: reduce(RC.users, %{})[user]["nick"]
      }
    }

    if msg.text do
      Hedwig.Robot.handle_in(robot, msg)
    end
    {:noreply, state}
  end

  def handle_call({:flows, flows}, _from, state) do
    {:reply, nil, %{state | flows: flows}}
  end

  def handle_call({:robot_name}, _from, %{opts: opts} = state) do
    {:reply, opts[:name], state}
  end

  def handle_info(:connection_ready, %{robot: robot} = state) do
    Hedwig.Robot.handle_connect(robot)
    {:noreply, state}
  end

  def handle_info(msg, %{robot: robot} = state) do
    Hedwig.Robot.handle_in(robot, msg)
    {:noreply, state}
  end

  defp flowdock_message(%Hedwig.Message{} = msg, overrides \\ %{}) do
    defaults = Map.merge(%{flow: msg.room, content: msg.text, event: msg.type}, overrides)
    if msg.private.thread_id do
      Map.merge(%{thread_id: msg.private[:thread_id]}, defaults)
    end
  end

  defp reduce(collection, acc) do
    Enum.reduce(collection, acc, fn item, acc ->
      Map.put(acc, "#{item["id"]}", item)
    end)
  end

  def parameterize_flow(flow) do
    "#{flow["organization"]["parameterized_name"]}/#{flow["parameterized_name"]}"
  end
end
