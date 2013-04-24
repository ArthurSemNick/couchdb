% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_io_regulator).
-behaviour(gen_server).

-export([start_link/0, io/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-record(state, {
    concurrency=10,
    ratio,
    interactive=queue:new(),
    compaction=queue:new(),
    running=[]
}).

-record(request, {
    fd,
    msg,
    class,
    from,
    ref
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

io(Fd, Msg) ->
    Request = #request{fd=Fd, msg=Msg, class=get(io_class), from=self()},
    gen_server:call(?MODULE, Request, infinity).

init(_) ->
    Ratio = list_to_float(couch_config:get("io", "ratio", "0.01")),
    {ok, #state{ratio=Ratio}}.

handle_call(#request{}=Request, From, State) ->
    {noreply, enqueue_request(Request#request{from=From}, State), 0}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Ref, Reply}, State) ->
    case lists:keytake(Ref, #request.ref, State#state.running) of
        {value, Request, Remaining} ->
            erlang:demonitor(Ref, [flush]),
            gen_server:reply(Request#request.from, Reply),
            {noreply, State#state{running=Remaining}, 0};
        false ->
            {noreply, State, 0}
    end;

handle_info({'DOWN', Ref, _, _, Reason}, State) ->
    case lists:keytake(Ref, #request.ref, State#state.running) of
        {value, Request, Remaining} ->
            gen_server:reply(Request#request.from, {'EXIT', Reason}),
            {noreply, State#state{running=Remaining}, 0};
        false ->
            {noreply, State, 0}
    end;

handle_info(timeout, State) ->
    {noreply, maybe_submit_request(State)}.

code_change(_Vsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

enqueue_request(#request{class=compaction}=Request, #state{}=State) ->
    State#state{compaction=queue:in(Request, State#state.compaction)};
enqueue_request(#request{}=Request, #state{}=State) ->
    State#state{interactive=queue:in(Request, State#state.interactive)}.

maybe_submit_request(#state{concurrency=Concurrency, running=Running}=State)
  when length(Running) < Concurrency ->
    case make_next_request(State) of
        State ->
            State;
        NewState when length(Running) >= Concurrency - 1 ->
            NewState;
        NewState ->
            maybe_submit_request(NewState)
    end;
maybe_submit_request(State) ->
    State.

make_next_request(#state{}=State) ->
    case {queue:is_empty(State#state.compaction), queue:is_empty(State#state.interactive)} of
        {true, true} ->
            State;
        {true, false} ->
            choose_next_request(#state.interactive, State);
        {false, true} ->
            choose_next_request(#state.compaction, State);
        {false, false} ->
            case random:uniform() < State#state.ratio of
                true ->
                    choose_next_request(#state.compaction, State);
                false ->
                    choose_next_request(#state.interactive, State)
            end
    end.

choose_next_request(Index, State) ->
    case queue:out(element(Index, State)) of
        {empty, _} ->
            State;
        {{value, Request}, Q} ->
            submit_request(Request, setelement(Index, State, Q))
    end.

submit_request(#request{}=Request, #state{}=State) ->
    Ref = erlang:monitor(process, Request#request.fd),
    Request#request.fd ! {'$gen_call', {self(), Ref}, Request#request.msg},
    State#state{running = [Request#request{ref=Ref} | State#state.running]}.
