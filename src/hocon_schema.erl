%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(hocon_schema).

%% behaviour APIs
-export([
    roots/1,
    fields/2,
    fields_and_meta/2,
    translations/1,
    translation/2,
    validations/1
]).

-export([
    find_structs/1,
    find_structs/2,
    override/2,
    namespace/1,
    resolve_struct_name/2,
    root_names/1,
    field_schema/2,
    assert_fields/2,
    path/1,
    readable_type/1,
    fmt_type/2,
    fmt_ref/2,
    is_deprecated/1
]).

-export([
    new_desc_cache/1,
    resolve_schema/2,
    delete_desc_cache/1
]).

-export_type([
    field_schema/0,
    name/0,
    schema/0,
    typefunc/0,
    translationfunc/0,
    desc/0
]).

-callback namespace() -> name().
-callback roots() -> [root_type()].
-callback fields(name()) -> fields().
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].
-callback validations() -> [validation()].
-callback desc(name()) -> iodata() | undefined.

-optional_callbacks([
    namespace/0,
    roots/0,
    fields/1,
    translations/0,
    translation/1,
    validations/0,
    desc/1
]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

-type name() :: atom() | string() | binary().
-type desc_id() :: atom() | string() | binary().
-type desc() :: iodata() | {desc, module(), desc_id()}.
%% primitive (or complex, but terminal) type
-type type() ::
    typerefl:type()
    %% reference to another struct
    | name()
    %% array of
    | ?ARRAY(type())
    %% one-of
    | ?UNION([type()])
    %% one-of atoms, data is allowed to be binary()
    | ?ENUM([atom()]).

-type field_schema() ::
    typerefl:type()
    | ?UNION([type()])
    | ?ARRAY(type())
    | ?ENUM(type())
    | field_schema_map()
    | field_schema_fun().

-type field_schema_fun() :: fun((_) -> _).
-type field_schema_map() ::
    #{
        type := type(),
        default => term(),
        examples => term(),
        mapping => undefined | string(),
        converter => undefined | translationfunc(),
        validator => undefined | validationfun(),
        %% set false if a field is allowed to be `undefined`
        %% NOTE: has no point setting it to `true` if field has a default value

        % default = false
        required => boolean() | {false, recursively},
        %% for sensitive data obfuscation (password, token)
        sensitive => boolean(),
        desc => desc(),
        %% hide it from doc generation
        hidden => boolean(),
        %% Set to {since, Version} to mark field as deprecated.
        %% deprecated field can not be removed due to compatibility reasons.
        %% The value will be dropped,
        %% Deprecated fields are treated as required => {false, recursively}
        deprecated => {since, binary()} | false,
        %% transparent metadata
        extra => map()
    }.

-type field() :: {name(), typefunc() | field_schema()}.
-type fields() ::
    [field()]
    | #{
        fields := [field()],
        desc => desc()
    }.
-type validation() :: {name(), validationfun()}.
-type root_type() :: name() | field().
-type schema() ::
    module()
    | #{
        roots := [root_type()],
        fields => #{name() => fields()} | fun((name()) -> fields()),
        %% for config mappings
        translations => #{name() => [translation()]},
        %% for config integrity checks
        validations => [validation()],
        namespace => atom()
    }.

-type translation() :: {name(), translationfunc()}.
-type typefunc() :: fun((_) -> _).
-type translationfunc() ::
    fun((hocon:config()) -> hocon:config())
    | fun((hocon:config(), map()) -> hocon:config()).
-type validationfun() :: fun((hocon:config()) -> ok | boolean() | {error, term()}).
-type bin_name() :: binary().

%% @doc Get translation identified by `Name' from the given schema.
-spec translation(schema(), name()) -> [translation()].
translation(Mod, Name) when is_atom(Mod) -> Mod:translation(Name);
translation(#{translations := Trs}, Name) -> maps:get(Name, Trs).

%% @doc Get all translations from the given schema.
-spec translations(schema()) -> [name()].
translations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, translations, 0) of
        false -> [];
        true -> Mod:translations()
    end;
translations(#{translations := Trs}) ->
    maps:keys(Trs);
translations(Sc) when is_map(Sc) -> [].

%% @doc Get all validations from the given schema.
-spec validations(schema()) -> [validation()].
validations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, validations, 0) of
        false -> [];
        true -> Mod:validations()
    end;
validations(Sc) ->
    maps:get(validations, Sc, []).

%% @doc Make a higher order schema by overriding `Base' with `OnTop'
-spec override(field_schema(), field_schema_map()) -> field_schema_fun().
override(Base, OnTop) ->
    fun(SchemaKey) ->
        case maps:is_key(SchemaKey, OnTop) of
            true -> field_schema(OnTop, SchemaKey);
            false -> field_schema(Base, SchemaKey)
        end
    end.

%% @doc Get namespace of a schema.
-spec namespace(schema()) -> undefined | binary().
namespace(Schema) ->
    case is_atom(Schema) of
        true ->
            case erlang:function_exported(Schema, namespace, 0) of
                true -> Schema:namespace();
                false -> undefined
            end;
        false ->
            maps:get(namespace, Schema, undefined)
    end.

%% @doc Resolve struct name from a guess.
resolve_struct_name(Schema, StructName) ->
    case lists:keyfind(bin(StructName), 1, roots(Schema)) of
        {_, {N, _Sc}} -> N;
        false -> throw({unknown_struct_name, Schema, StructName})
    end.

%% @doc Get all root names from a schema.
-spec root_names(schema()) -> [binary()].
root_names(Schema) -> [Name || {Name, _} <- roots(Schema)].

%% @doc Get exported root fields in format [{BinaryName, {OriginalName, FieldSchema}}].
-spec roots(schema()) -> [{bin_name(), {name(), field_schema()}}].
roots(Schema) ->
    All =
        lists:map(
            fun
                ({N, T}) -> {bin(N), {N, T}};
                (N) when is_atom(Schema) -> {bin(N), {N, ?R_REF(Schema, N)}};
                (N) -> {bin(N), {N, ?REF(N)}}
            end,
            do_roots(Schema)
        ),
    AllNames = [Name || {Name, _} <- All],
    UniqueNames = lists:usort(AllNames),
    case length(UniqueNames) =:= length(AllNames) of
        true ->
            All;
        false ->
            error({duplicated_root_names, AllNames -- UniqueNames})
    end.

do_roots(Mod) when is_atom(Mod) -> Mod:roots();
do_roots(#{roots := Names}) -> Names.

%% @doc Get fields of the struct for the given struct name.
-spec fields(schema(), name()) -> [field()].
fields(Sc, Name) ->
    #{fields := Fields} = fields_and_meta(Sc, Name),
    Fields.

%% @doc Get fields and meta data of the struct for the given struct name.
-spec fields_and_meta(schema(), name()) -> fields().
fields_and_meta(Mod, Name) when is_atom(Mod) ->
    case Mod:fields(Name) of
        Fields when is_list(Fields) ->
            maybe_add_desc(Mod, Name, #{fields => Fields});
        Fields ->
            ensure_struct_meta(Fields)
    end;
fields_and_meta(#{fields := Fields}, Name) when is_function(Fields) ->
    ensure_struct_meta(Fields(Name));
fields_and_meta(#{fields := Fields}, Name) when is_map(Fields) ->
    ensure_struct_meta(maps:get(Name, Fields)).

maybe_add_desc(Mod, Name, Meta) ->
    case erlang:function_exported(Mod, desc, 1) of
        true ->
            case Mod:desc(Name) of
                undefined ->
                    Meta;
                Desc ->
                    Meta#{desc => Desc}
            end;
        false ->
            Meta
    end.

ensure_struct_meta(Fields) when is_list(Fields) -> #{fields => Fields};
ensure_struct_meta(#{fields := _} = Fields) -> Fields.

find_structs(Schema, Fields) ->
    find_structs(Schema, Fields, #{}, _ValueStack = [], _TypeStack = []).

find_structs(Schema, #{fields := Fields}, Acc, Stack, TStack) ->
    find_structs(Schema, Fields, Acc, Stack, TStack);
find_structs(_Schema, [], Acc, _Stack, _TStack) ->
    Acc;
find_structs(Schema, [{FieldName, FieldSchema} | Fields], Acc0, Stack, TStack) ->
    Type = field_schema(FieldSchema, type),
    Acc = find_structs_per_type(Schema, Type, Acc0, [str(FieldName) | Stack], TStack),
    find_structs(Schema, Fields, Acc, Stack, TStack).

find_structs_per_type(Schema, Name, Acc, Stack, TStack) when is_list(Name) ->
    find_ref(Schema, Name, Acc, Stack, TStack);
find_structs_per_type(Schema, ?REF(Name), Acc, Stack, TStack) ->
    find_ref(Schema, Name, Acc, Stack, TStack);
find_structs_per_type(_Schema, ?R_REF(Module, Name), Acc, Stack, TStack) ->
    find_ref(Module, Name, Acc, Stack, TStack);
find_structs_per_type(Schema, ?LAZY(Type), Acc, Stack, TStack) ->
    find_structs_per_type(Schema, Type, Acc, Stack, TStack);
find_structs_per_type(Schema, ?ARRAY(Type), Acc, Stack, TStack) ->
    find_structs_per_type(Schema, Type, Acc, ["$INDEX" | Stack], TStack);
find_structs_per_type(Schema, ?UNION(Types), Acc, Stack, TStack) ->
    lists:foldl(
        fun(T, AccIn) ->
            find_structs_per_type(Schema, T, AccIn, Stack, TStack)
        end,
        Acc,
        Types
    );
find_structs_per_type(Schema, ?MAP(Name, Type), Acc, Stack, TStack) ->
    find_structs_per_type(Schema, Type, Acc, ["$" ++ str(Name) | Stack], TStack);
find_structs_per_type(_Schema, _Type, Acc, _Stack, _TStack) ->
    Acc.

find_ref(Schema, Name, Acc, Stack, TStack) ->
    Namespace = namespace(Schema),
    Key = {Namespace, Schema, Name},
    Path = path(Stack),
    Paths =
        case maps:find(Key, Acc) of
            {ok, #{paths := Ps}} -> Ps;
            error -> #{}
        end,
    case lists:member(Key, TStack) of
        true ->
            %% loop reference, break here, otherwise never exit
            Acc;
        false ->
            Fields0 = fields_and_meta(Schema, Name),
            Fields = Fields0#{paths => Paths#{Path => true}},
            find_structs(Schema, Fields, Acc#{Key => Fields}, Stack, [Key | TStack])
    end.

%% @doc Collect all structs defined in the given schema.
-spec find_structs(schema()) ->
    {RootNs :: name(), RootFields :: [field()], [{Namespace :: name(), Name :: name(), fields()}]}.
find_structs(Schema) ->
    RootFields = unify_roots(Schema),
    All = find_structs(Schema, RootFields),
    RootNs = hocon_schema:namespace(Schema),
    {RootNs, RootFields, [
        {Ns, Name, Fields}
     || {{Ns, _Schema, Name}, Fields} <- lists:keysort(1, maps:to_list(All))
    ]}.

unify_roots(Schema) ->
    Roots = ?MODULE:roots(Schema),
    lists:map(
        fun({_BinName, {RootFieldName, RootFieldSchema}}) ->
            {RootFieldName, RootFieldSchema}
        end,
        Roots
    ).

str(A) when is_atom(A) -> atom_to_list(A);
str(S) when is_list(S) -> S.

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(S) -> unicode:characters_to_binary(S, utf8).

%% get type validation stack.
path(Stack) when is_list(Stack) ->
    string:join(lists:reverse(lists:map(fun str/1, Stack)), ".").

field_schema(Atom, type) when is_atom(Atom) -> Atom;
field_schema(Atom, _Other) when is_atom(Atom) -> undefined;
field_schema(Type, SchemaKey) when ?IS_TYPEREFL(Type) ->
    field_schema(hoconsc:mk(Type), SchemaKey);
field_schema(?MAP(_Name, _Type) = Map, SchemaKey) ->
    field_schema(hoconsc:mk(Map), SchemaKey);
field_schema(?LAZY(_) = Lazy, SchemaKey) ->
    field_schema(hoconsc:mk(Lazy), SchemaKey);
field_schema(Ref, SchemaKey) when is_list(Ref) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?REF(_) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?R_REF(_, _) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?ARRAY(_) = Array, SchemaKey) ->
    field_schema(hoconsc:mk(Array), SchemaKey);
field_schema(?UNION(_) = Union, SchemaKey) ->
    field_schema(hoconsc:mk(Union), SchemaKey);
field_schema(?ENUM(_) = Enum, SchemaKey) ->
    field_schema(hoconsc:mk(Enum), SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_function(FieldSchema, 1) ->
    FieldSchema(SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_map(FieldSchema) ->
    maps:get(SchemaKey, FieldSchema, undefined).

%% @doc Assert fields schema sanity.
assert_fields(EnclosingSchema, []) ->
    error(#{reason => no_fields_defined, enclosing_schema => EnclosingSchema});
assert_fields(EnclosingSchema, Fields) ->
    case assert_unique_field_names(Fields) of
        ok -> ok;
        {error, Reason} -> error(Reason#{enclosing_schema => EnclosingSchema})
    end.

assert_unique_field_names(Fields) ->
    assert_unique_field_names(Fields, []).

assert_unique_field_names([], _) ->
    ok;
assert_unique_field_names([{Name, _} | Rest], Acc) ->
    BinName = bin(Name),
    case lists:member(BinName, Acc) of
        true ->
            {error, #{
                reason => duplicated_field_name,
                name => Name
            }};
        false ->
            assert_unique_field_names(Rest, [BinName | Acc])
    end.

new_desc_cache(undefined) ->
    #{file => undefined, tab => undefined};
new_desc_cache(File) ->
    case hocon:load(File) of
        {ok, Schema} ->
            Tab = ets:new(?MODULE, [set]),
            maps:map(
                fun(Mod, ModMap) ->
                    maps:map(
                        fun(Id, SubMap) ->
                            ets:insert(Tab, {{Mod, Id}, SubMap})
                        end,
                        ModMap
                    )
                end,
                Schema
            ),
            #{tab => Tab, file => File};
        {error, Reason} ->
            error(#{reason => Reason, file => File})
    end.

delete_desc_cache(#{tab := undefined}) -> ok;
delete_desc_cache(#{tab := Tab}) -> ets:delete(Tab).

resolve_schema(?DESC(Mod, Id), State) ->
    case get_cache_desc(State, bin(Mod), bin(Id)) of
        undefined -> error(#{reason => no_desc_for_id, key => {Mod, Id}, state => State});
        Desc -> Desc
    end;
resolve_schema(Any, _State) ->
    Any.

get_cache_desc(#{tab := undefined}, _, _) ->
    undefined;
get_cache_desc(#{tab := Tab}, Mod, Id) ->
    case ets:lookup(Tab, {Mod, Id}) of
        [{_, Desc}] -> Desc;
        [] -> undefined
    end.

readable_type(T) ->
    case fmt_type(undefined, T) of
        #{name := Name} -> Name;
        #{kind := Kind} -> Kind
    end.

fmt_type(_Ns, A) when is_atom(A) ->
    #{
        kind => singleton,
        name => bin(A)
    };
fmt_type(Ns, Ref) when is_list(Ref) ->
    fmt_type(Ns, ?REF(Ref));
fmt_type(Ns, ?REF(Ref)) ->
    #{
        kind => struct,
        name => bin(fmt_ref(Ns, Ref))
    };
fmt_type(_Ns, ?R_REF(Module, Ref)) ->
    fmt_type(hocon_schema:namespace(Module), ?REF(Ref));
fmt_type(Ns, ?ARRAY(T)) ->
    #{
        kind => array,
        elements => fmt_type(Ns, T)
    };
fmt_type(Ns, ?UNION(Ts)) ->
    #{
        kind => union,
        members => [fmt_type(Ns, T) || T <- Ts]
    };
fmt_type(_Ns, ?ENUM(Symbols)) ->
    #{
        kind => enum,
        symbols => [bin(S) || S <- Symbols]
    };
fmt_type(Ns, ?LAZY(T)) ->
    fmt_type(Ns, T);
fmt_type(Ns, ?MAP(Name, T)) ->
    #{
        kind => map,
        name => bin(Name),
        values => fmt_type(Ns, T)
    };
fmt_type(_Ns, Type) when ?IS_TYPEREFL(Type) ->
    #{
        kind => primitive,
        name => bin(typerefl:name(Type))
    }.

fmt_ref(undefined, Name) ->
    Name;
fmt_ref(Ns, Name) ->
    %% when namespace is the same as reference name
    %% we do not prepend the reference link with namespace
    %% because the root name is already unique enough
    case bin(Ns) =:= bin(Name) of
        true -> Name;
        false -> <<(bin(Ns))/binary, ":", (bin(Name))/binary>>
    end.

%% @doc Return 'true' if the field is marked as deprecated.
-spec is_deprecated(field_schema()) -> boolean().
is_deprecated(Schema) ->
    IsDeprecated = field_schema(Schema, deprecated),
    IsDeprecated =/= undefined andalso IsDeprecated =/= false.
