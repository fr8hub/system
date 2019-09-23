defmodule X3m.System.MessageHandler do
  defmacro on_new_aggregate(cmd, opts \\ []) do
    id_field = Keyword.get(opts, :id, "id")

    quote do
      @doc """
      Handles `message` for new aggregate with id specified in `message.raw_request`
      under `#{inspect(unquote(id_field))}` key and then proxing both values to it.

      It handles aggregate's response, processing any events it returned in response
      `message.events` and then sending `message.response` to the caller process
      specified in `message.reply_to`.
      """
      @spec unquote(cmd)(X3m.System.Message.t()) :: {:reply, X3m.System.Message.t()}
      def unquote(cmd)(%X3m.System.Message{} = message) do
        case X3m.System.Message.prepare_aggregate_id(message, unquote(id_field),
               generate_if_missing: true
             ) do
          %X3m.System.Message{halted?: true} = msg ->
            msg

          %X3m.System.Message{halted?: false} = msg ->
            execute_on_new_aggregate(unquote(cmd), msg)
        end
        |> __respond_on()
      end
    end
  end

  defmacro on_aggregate(cmd, opts \\ []) do
    id_field = Keyword.get(opts, :id, "id")

    quote do
      @doc """
      Handles `message` for existing aggregate with id specified in `message.raw_request`
      under `#{inspect(unquote(id_field))}` key, preparing it's state and then proxing
      both values to it.

      It handles aggregate's response, processing any events it returned in response
      `message.events` and then sending `message.response` to the caller process
      specified in `message.reply_to`.
      """
      @spec unquote(cmd)(X3m.System.Message.t()) :: {:reply, X3m.System.Message.t()}
      def unquote(cmd)(%X3m.System.Message{} = message) do
        case X3m.System.Message.prepare_aggregate_id(message, unquote(id_field)) do
          %X3m.System.Message{halted?: true} = msg ->
            msg

          %X3m.System.Message{halted?: false} = msg ->
            execute_on_aggregate(unquote(cmd), msg)
        end
        |> __respond_on()
      end
    end
  end

  defmacro __using__(opts) do
    quote do
      require Logger
      require X3m.System.MessageHandler
      import X3m.System.MessageHandler

      @aggregate_mod Keyword.fetch!(unquote(opts), :aggregate_mod)
      @repo Keyword.fetch!(unquote(opts), :aggregate_repo)
      @stream Keyword.get(unquote(opts), :stream)
      @pid_facade_mod Keyword.fetch!(unquote(opts), :pid_facade_mod)
      @pid_facade_name @pid_facade_mod.name(@aggregate_mod)
      @gen_aggregate_mod @pid_facade_mod.get_aggregate_mod()

      defp aggregate_mod,
        do: @aggregate_mod

      defp execute_on_new_aggregate(cmd, %X3m.System.Message{aggregate_meta: %{id: id}} = message) do
        with {:ok, pid} <- @pid_facade_mod.spawn_new(@pid_facade_name, id),
             {:block, %X3m.System.Message{} = message, transaction_id} <-
               @gen_aggregate_mod.handle_msg(pid, cmd, message),
             {:ok, version} <- _apply_changes(pid, transaction_id, message) do
          case message.response do
            {:created, ^id} -> %X3m.System.Message{message | response: {:created, id, version}}
            other -> message
          end
        else
          {:noblock, %X3m.System.Message{} = message, _state} ->
            Logger.warn(fn -> "New aggregate creation failed: #{inspect(message.response)}" end)

            @pid_facade_mod.exit_process(
              @pid_facade_name,
              id,
              {:creation_failed, message.response}
            )

            message

          error ->
            error
        end
      end

      defp execute_on_aggregate(cmd, %X3m.System.Message{aggregate_meta: %{id: id}} = message) do
        with {:ok, pid} <-
               @pid_facade_mod.get_pid(@pid_facade_name, id, &when_pid_is_not_registered/3),
             {:block, %X3m.System.Message{} = message, transaction_id} <-
               @gen_aggregate_mod.handle_msg(pid, cmd, message),
             {:ok, version} <- _apply_changes(pid, transaction_id, message) do
          case message.response do
            :ok -> %X3m.System.Message{message | response: {:ok, version}}
            {:ok, any} -> %X3m.System.Message{message | response: {:ok, any, version}}
            other -> message
          end
        else
          {:noblock, %X3m.System.Message{} = message, _state} ->
            Logger.debug(fn -> ":noblock returned: #{inspect(message)}" end)

            case message.response do
              :ok ->
                %X3m.System.Message{message | response: {:ok, message.aggregate_meta.version}}

              {:ok, any} ->
                %X3m.System.Message{
                  message
                  | response: {:ok, any, message.aggregate_meta.version}
                }

              other ->
                message
            end

          error ->
            error
        end
      end

      defp exit_process(id, reason \\ :normal),
        do: @pid_facade_mod.exit_process(@pid_facade_name, id, reason)

      defp delete_stream(id, soft_or_hard, expected_version \\ -2)
           when soft_or_hard in ~w(soft hard)a do
        hard_delete? = soft_or_hard == :hard

        id
        |> stream_name()
        |> @repo.delete_stream(hard_delete?, expected_version)
      end

      @doc false
      # Should return {:ok, last_event_number} on success, otherwise aggregate will be terminated and
      # that result will be returned to the caller
      @spec save_events(X3m.System.Message.t()) ::
              {:ok, integer}
              | {:error, :wrong_expected_version, integer}
              | {:error, any}
      def save_events(%X3m.System.Message{} = message) do
        message.aggregate_meta.id
        |> stream_name()
        |> @repo.save_events(message)
      end

      @doc false
      def stream_name(id) when is_binary(id), do: @stream <> "-" <> id
      def stream_name(id), do: id |> to_string |> stream_name

      @doc false
      def save_state(id, state),
        do: :ok

      @doc false
      # def when_pid_is_not_registered,
      #  do: fn aggregate_mod, key, spawn_new_fun ->
      #    get_from_es(aggregate_mod, key, spawn_new_fun)
      #  end

      # Should return function that takes `aggregate_mod`, `id`, `spawn_new_fun` and returns {:ok, pid} or `anything`.
      # If `anything` is returned, `with_aggregate` will return that value and won't run command on aggregate
      def when_pid_is_not_registered(aggregate_mod, id, spawn_new_fun),
        do: get_from_es(aggregate_mod, id, spawn_new_fun)

      defp get_from_es(aggregate_mod, id, spawn_new_fun) do
        id
        |> stream_name()
        |> @repo.has?()
        |> case do
          true ->
            {:ok, pid} = spawn_new_fun.()

            events =
              id
              |> stream_name()
              |> @repo.stream_events()

            Logger.debug(fn -> "Applying events for existing aggregate #{id}" end)
            :ok = @gen_aggregate_mod.apply_event_stream(pid, events)
            {:ok, pid}

          false ->
            Logger.warn(fn -> "No events found for aggregate: #{id}" end)
            {:error, :not_found}
        end
      end

      defp _apply_changes(pid, transaction_id, %X3m.System.Message{} = message) do
        case save_events(message) do
          {:ok, last_event_number} ->
            {:ok, new_state} =
              @gen_aggregate_mod.commit(pid, transaction_id, message, last_event_number)

            Logger.info(fn ->
              "Successfull commit of events. New aggregate version: #{last_event_number}"
            end)

            :ok = save_state(message.aggregate_meta.id, new_state)
            {:ok, last_event_number}

          error ->
            Logger.error(fn -> "Error saving events #{inspect(error)}" end)
            Process.exit(pid, :kill)
            X3m.System.Message.error(message, :internal_error)
        end
      end

      defp __respond_on(%X3m.System.Message{} = message),
        do: {:reply, message}

      defoverridable when_pid_is_not_registered: 3
    end
  end
end