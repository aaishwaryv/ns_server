%% @author Couchbase <info@couchbase.com>
%% @copyright 2020 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(yaml).

-export([encode/1, preprocess/1]).
-export_type([yaml_term/0]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


-type yaml_term() :: yaml_term(number() | atom() | binary() |
                               {Format :: string(), Args :: [term()]}).
-type yaml_term_preprocessed() :: yaml_term(number() | atom() | binary()).
-type yaml_term(ValueType) :: ValueType |
                              #{atom() => yaml_term(ValueType)} |
                              [yaml_term(ValueType)].

-spec encode(yaml_term()) -> binary().
encode(Term) ->
    iolist_to_binary(lists:join("\n", format(preprocess(Term)))).

%% The main purpose of the preprocess function is to format all
%% {Format, Args} parts of yaml term to regular binary.
-spec preprocess(yaml_term()) -> yaml_term_preprocessed().
preprocess(#{} = Map) ->
    maps:map(fun (_, V) -> preprocess(V) end, Map);
preprocess(List) when is_list(List) ->
    [preprocess(E) || E <- List];
preprocess({Format, Args}) ->
    iolist_to_binary(io_lib:format(Format, Args));
preprocess(Value) -> Value.

-ifdef(TEST).
preprocess_test() ->
    ?assertEqual(preprocess([]), []),
    ?assertEqual(preprocess(#{}), #{}),
    ?assertEqual(preprocess(1), 1),
    ?assertEqual(preprocess(<<"bin">>), <<"bin">>),
    ?assertEqual(preprocess({"~b-~s", [42, "test"]}), <<"42-test">>),
    ?assertEqual(preprocess(#{key => [<<"bin">>, {"~b-~s", [42, "test"]}]}),
                            #{key => [<<"bin">>, <<"42-test">>]}).
-endif.

format(#{} = Map) ->
    lists:flatmap(
      fun ({K, V}) ->
          KBin = if
                     is_atom(K) -> atom_to_binary(K, latin1);
                     is_binary(K) -> K
                 end,
          case format(V) of
              [] -> [[KBin, ":"]];
              [Line] when not is_list(V),
                          not is_map(V) -> [[KBin, ": ", Line]];
              [_|_] = MultiLine ->
                  [[KBin, ":"]] ++
                  ["  " ++ L || L <- MultiLine]
          end
      end, maps:to_list(Map));
format([]) ->
    [];
format([El | Tail]) ->
    case format(El) of
        [] ->
            ["-"];
        Lines when is_list(El) ->
            ["-"] ++ ["  " ++ L || L <- Lines];
        [First | Rest] ->
            ["- " ++ First] ++ ["  " ++ L || L <- Rest]
    end ++ format(Tail);
format(N) when is_integer(N) ->
    [integer_to_binary(N)];
format(F) when is_float(F) ->
    [float_to_binary(F)];
format(A) when is_atom(A) ->
    [["'", atom_to_binary(A, latin1), "'"]];
format(B) when is_binary(B) ->
    [["'", B, "'"]].

-ifdef(TEST).
encode_test() ->
    ?assertEqual(encode([]), <<>>),
    ?assertEqual(encode(#{}), <<>>),
    ?assertEqual(encode([atom1, <<"bin">>, 123, {"format ~b and ~b", [1, 2]}]),
                 <<"- 'atom1'\n"
                   "- 'bin'\n"
                   "- 123\n"
                   "- 'format 1 and 2'">>),
    ?assertEqual(encode(#{atom1 => 123, <<"binary1">> => atom2}),
                 <<"atom1: 123\n"
                   "binary1: 'atom2'">>),
    ?assertEqual(encode([[], [1, 2]]),
                 <<"-\n"
                   "-\n"
                   "  - 1\n"
                   "  - 2">>),
    ?assertEqual(encode(#{key => #{subkey => 1}}),
                 <<"key:\n"
                   "  subkey: 1">>),
    ?assertEqual(encode([#{key => {"int: ~b", [123]}}]),
                 <<"- key: 'int: 123'">>),
    ?assertEqual(encode(#{global =>
                            #{scrape_interval => <<"10s">>,
                              scrape_timeout  => <<"20s">>},
                          scrape_configs => [
                              #{job_name => general,
                                metrics_path => <<"/_prometheusMetrics">>,
                                basic_auth =>
                                  #{username => <<"test">>,
                                    password_file => <<"/test/path">>},
                                static_configs => [
                                    #{targets => [<<"127.0.0.1:9000">>,
                                                  <<"[::1]:9200">>]}
                                  ],
                                metric_relabel_configs => [
                                    #{source_labels => [<<"__name__">>],
                                      target_label => <<"name">>}
                                  ],
                                relabel_configs => [
                                    #{regex => <<"127\\.0\\.0\\.1:9000">>,
                                      source_labels => [<<"__address__">>],
                                      target_label => instance,
                                      replacement => ns_server},
                                    #{regex => <<"127\\.0\\.0\\.1:9200">>,
                                      source_labels => [<<"__address__">>],
                                      target_label => instance,
                                      replacement => fts}
                                  ]}]}),
                 <<"global:\n"
                   "  scrape_interval: '10s'\n"
                   "  scrape_timeout: '20s'\n"
                   "scrape_configs:\n"
                   "  - basic_auth:\n"
                   "      password_file: '/test/path'\n"
                   "      username: 'test'\n"
                   "    job_name: 'general'\n"
                   "    metric_relabel_configs:\n"
                   "      - source_labels:\n"
                   "          - '__name__'\n"
                   "        target_label: 'name'\n"
                   "    metrics_path: '/_prometheusMetrics'\n"
                   "    relabel_configs:\n"
                   "      - regex: '127\\.0\\.0\\.1:9000'\n"
                   "        replacement: 'ns_server'\n"
                   "        source_labels:\n"
                   "          - '__address__'\n"
                   "        target_label: 'instance'\n"
                   "      - regex: '127\\.0\\.0\\.1:9200'\n"
                   "        replacement: 'fts'\n"
                   "        source_labels:\n"
                   "          - '__address__'\n"
                   "        target_label: 'instance'\n"
                   "    static_configs:\n"
                   "      - targets:\n"
                   "          - '127.0.0.1:9000'\n"
                   "          - '[::1]:9200'">>).

-endif.
