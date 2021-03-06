%%%============================================================================
%%% File     : eburg_backend.erl
%%% Purpose  : BURM emitter.
%%% Author   : j@svirfneblin.org
%%% License  : BSD
%%% Created  : 2007-09-21 11:56:51 j
%%% Modified : $Id: eburg_backend.erl,v 1.1.1.1 2008/08/07 16:31:33 j Exp $
%%%============================================================================

%%%_. Attributes

-module(eburg_backend).
-author('j@svirfneblin.org').

-import(eburg_util, [sget/3, assoc/2, is_tainted/2, has_closure/2, irn2prn/3,
                     die/1,
                     c/1, c/2, e/1, e/2, mkcode/3, emitcode/3, emitcode2/3,
                     gsub/3, match/2,
                     unparse_rule_short/1,
                     enumerate/1, gensym/1, pp/1]).

-export([emit/1]).

-include("eburg.hrl").


%%%_. Interface
%%% Most of BURM is printed directly to the output file.
%%% The convention is that `emit_*' routines print to ```get('$out_stream')'''
%%% whereas `gen_*' routines return code (strings) for inclusion in some
%%% `emit_*' routine.

-spec(emit/1 :: (#eburg{}) -> ok).
%% @doc Opens and registers the global output stream and calls the
%% top-level `emit_*' routines.
%% @todo make pretty printing optional
%% @todo add more burm runtime error checks?
emit(St) ->
    case file:open(St#eburg.outfile, [write]) of
        {error,Reason} ->
            die({St#eburg.outfile, {file,Reason}});
        {ok,Stream} ->
            try
                put('$out_stream', Stream),
                e("%%% Generated by eburg, do not modify."),
                emit_preamble(St),
                emit_labeler(St),
                emit_reducer(St),
                e("%%% eof"),
                pp(St#eburg.outfile)
            after
                file:close(Stream),
                erase('$out_stream')
            end
    end.


%%%_. Preamble

emit_preamble(St) ->
    emit_dcls(St),
    emit_inn_macs(St),
    emit_user_code(St),
    emit_rewrite(St),
    emit_dumpcover(St),
    emit_dump(St),
    emit_load(St).


emit_dcls(St) ->
    e("-module(~s).", [St#eburg.module]),
    e("-author(eburg)."),
    e("-compile(nowarn_unused_vars)."),
    %% We need to export functions in burm.hrl here and include burm.hrl after
    %% the user code since that may contain export declarations as well.
    e("-export([rewrite/1, label/1, reduce/2, format_error/1,"),
    e("         dumpcover/1, dumplabels/1, dump/0]).").


emit_inn_macs(St) ->
    emitcode(blank, "-define(~p, ~p).", St#eburg.inns).


%% @todo copy user code verbatim
emit_user_code(St) ->
    e("%%~s", [duplicate(77, $-)]),
    foreach(fun(Form) -> e(erl_prettypr:format(Form)) end, St#eburg.code),
    e("%%~s", [duplicate(77, $-)]),
    e(""),
    e("-include(\"burm.hrl\").").


emit_rewrite(St) ->
    e("rewrite(Tree) -> reduce(label(Tree), ?~s).", [St#eburg.start]).


emit_dumpcover(St) ->
    e("dumpcover(Tree) ->"),
    e("    dumpcover(Tree, ?~s, 0),", [St#eburg.start]),
    e("    io:format(\"~n\").").


%% @todo dump to single file
emit_dump(St) ->
    F = St#eburg.module,
    e("dump() ->"),
    e("    ets:tab2file(burm_id_cache, \"~s.ids\"),"      , [F]),
    e("    ets:tab2file(burm_state_cache, \"~s.states\"),", [F]),
    e("    ets:tab2file(burm_swdc_cache, \"~s.swdcs\")."  , [F]).


emit_load(St) ->
    Files = [St#eburg.module ++ Tab || Tab <- [".ids", ".states", ".swdcs"]],
    e("burm_maybe_load() ->"),
    e("    Results = [ets:file2tab(F) || F <- ~p],", [Files]),
    %% XXX: huh?
    e("    not lists:member(error, [element(1, R) || R <- Results]).").


%%%_. Labeler

emit_labeler(St) ->
    emit_state(St),
    emit_closures(St),
    emit_packtabs(St),
    emit_dyncost(St),
    emit_is_tainted(St).


%%%_ , Leaves
%%% We simulate the two-stage labeling process (recording baserules and
%%% computing the chainrule closure) at compile-compile time for static leaves.
%%% Note that here we use tuples of tuples rather than #burm_state{} records
%%% to represent state labels.

-type(state() :: {tuple(),tuple()}).

-spec(static_leaves/1 :: (#eburg{}) -> [atom()]).
%% @doc Returns those leaves whose rules all have static costs.
static_leaves(St) ->
    [L || L <- St#eburg.ops, sget(L, arity, St) =:= 0, not is_tainted(L, St)].


-spec(sim_leaf/2 :: (atom(),#eburg{}) -> state()).
%% @doc Returns the state label for `Leaf'.
sim_leaf(Leaf, St) ->
    Init = vector(St),
    foldl(fun(Rule, State) -> sim_rule(Rule, State, St) end,
          {Init,Init},
          sget(Leaf, brules, St)).


-spec(vector/1 :: (#eburg{}) -> tuple()).
%% @doc Returns a tuple which may be used to hold the cost or rule parts of a
%% state label.
vector(St) -> list_to_tuple(duplicate(length(St#eburg.nts), ?INFINITY)).


-spec(sim_rule/3 :: (#rule{},state(),#eburg{}) -> state()).
%% @doc Returns the result of recording `Rule' in `State'.
sim_rule(Rule, State, St) ->
    %% base cost ist zero since leaves have no kids
    sim_record(Rule, State, 0, St).


-spec(sim_record/4 :: (#rule{},state(),integer(),#eburg{}) -> state()).
%% @doc Returns the result of recording `R' in `State'.
sim_record(#rule{number=N,lhs=Nt,cost=Cost}, State={C0,R0}, B0, St) ->
    B1 = B0 + Cost, % known to be integer
    M  = sget(Nt, inn, St),
    case B1 < element(M, C0) of
        true ->
            C1 = setelement(M, C0, B1),
            R1 = setelement(M, R0, N),
            sim_closure(Nt, {C1,R1}, B1, St);
        false ->
            State
    end.


-spec(sim_closure/4 :: (atom(),state(),integer(),#eburg{}) -> state()).
%% @doc Returns the closure of `State' under `Nt'.
sim_closure(Nt, State0, B0, St) ->
    foldl(fun (Rule, State) -> sim_record(Rule, State, B0, St) end,
          State0,
          sget(Nt, crules, St)).


%%%_ , Rule packing

-spec(emit_packtabs/1 :: (#eburg{}) -> ok).
%% @doc Prints the tables used for rule packing.
emit_packtabs(St) ->
    emit_getrule(St#eburg.pmap),
    emit_decode(St#eburg.pmap),
    emit_setrule(St#eburg.pmap).


-spec(var/1 :: (atom()) -> string()).
%% @doc Variable constructor.
var(Atom) ->
    Upcase = fun(X) when $a=<X, X=<$z -> X + $A-$a end,
    [C|Cs] = atom_to_list(Atom),
    [Upcase(C)|Cs].


-spec(emit_getrule/1 :: (pmap()) -> ok).
%% @doc Prints one `burm_rule' clause for each nonterminal.
emit_getrule(Pmap) ->
    Args = [{Nt,gen_binary(Pmap),Nt,var(Nt)} || {Nt,_,_} <- Pmap],
    emitcode(func, "burm_rule(?~p, ~s) -> burm_decode_~p(~s)", Args).


-spec(gen_binary/1 :: (pmap()) -> string()).
%% @doc Returns code for the rule part of a state label.
gen_binary(Pmap) ->
    Args = [{var(Nt),Bs} || {Nt,Bs,_} <- Pmap],
    mkcode(bin, "~s:~p", Args).


-spec(emit_decode/1 :: (pmap()) -> ok).
%% @doc Prints the PRN decoding table.
emit_decode(Pmap) -> foreach(fun emit_decode_/1, Pmap).

emit_decode_({Nt,_,Rs}) ->
    Args = [{Nt,PRN,IRN} || {IRN,PRN} <- Rs],
    emitcode(func, "burm_decode_~p(~p) -> ~p", Args).


-spec(emit_setrule/1 :: (pmap()) -> ok).
%% @doc Prints one `burm_setrule' clause for each nonterminal.
emit_setrule(Pmap) ->
    Bin  = gen_binary(Pmap),
    Args = [{Nt,Bin,new_binary(Bin, var(Nt))} || {Nt,_,_} <- Pmap],
    emitcode(func, "burm_setrule(?~p, ~s, Rule) -> ~s", Args).

new_binary(Bin0, Nt) ->
    Fun = which(Bin0, Nt),
    {ok,Bin1,1} = gsub(Bin0, Fun(Nt), Fun("Rule")),
    Bin1.

which(Bin, Var) ->
    case match(Bin, first_segment(Var)) of
        true  -> fun first_segment/1;
        false -> fun segment/1
    end.

first_segment(S) -> "<" ++ S ++ ":".
segment(S)       -> "," ++ S ++ ":".


%%%_ , Label calculation
%%% To find the optimal rule cover, BURM has to check, at each node, which
%%% nonterminals can be derived (and at what cost) using the baserules for
%%% the operator at that node and, having done that, whether any additional
%%% nonterminals can be derived using chainrules.
%%%
%%% Three things need to be done for each rule
%%%   (1) Check whether the rule matches the subtree rooted at the current node
%%%       (baserules only)
%%%   (2) Check whether the rule should be used (i.e., could some nonterminal
%%%       be derived more cheaply using the new rule?)
%%%   (3) If the rule should be used, record that fact in the state label
%%%
%%% The code to do (1)-(3) for the rules of a single operator is contained
%%% in the body of a clause of the case statement in `burm_state'. This code
%%% assumes that the initial cost and rule tuples are in `BurmIC' and `BurmIR';
%%% `burm_state' assumes that each case clause will put the final cost and rule
%%% tuples into `BurmFC' and `BurmFR'.

emit_state(St) ->
    e("burm_state(BurmNode) ->"),
    e("    BurmIC = ~p,", [vector(St)]),
    e("    BurmIR = ~s,", [mkcode(bin, "0:~p", [St#eburg.rvsize])]),
    e("    case op_label(BurmNode) of"),
    emit_cases(St),
    e("    end,"),
    e("    #burm_state{cost = BurmFC, rule = BurmFR}.").


-spec(emit_cases/1 :: (#eburg{}) -> ok).
%% @doc Prints the body of the case statement in `burm_state'.
emit_cases(St) ->
    Ls = static_leaves(St),
    emitcode2(cbody,
              fun({Op, Rs}) ->
                      e("~p ->", [Op]),
                      case member(Op, Ls) of
                          true ->
                              {C, R0} = sim_leaf(Op, St),
                              R1      = gen_packed(R0, St),
                              e("{BurmFC, BurmFR} = {~p, ~s}", [C, R1]);
                          false ->
                              e("burm_assert(length(kids(BurmNode)) =:= ~p),",
                                [sget(Op, arity, St)]),
                              emit_clause_body(Rs, St)
                      end
              end,
              St#eburg.brules). % every op has baserules (normalized!)


-spec(gen_packed/2 :: ({integer()},#eburg{}) -> string()).
%% @doc Returns code for a binary containing the packed representation of
%% `Rvector'.
gen_packed(Rvector, St) ->
    %% A rule vector {r0, r1, ... rN} is interpreted as follows:
    %% ri is the internal rule number of the rule used to reduce the current
    %% node to the nonterminal with INN i.
    Args = [{assoc(I, I2P),Bits} ||
               {I,{_Nt,Bits,I2P}} <- zip(tuple_to_list(Rvector), % IRNs
                                         St#eburg.pmap)], % Nt implicit in pos
    mkcode(bin, "~p:~p", Args).


%%% Since intermediate versions of a node's state label have to be stored
%%% in different variables (and there may be arbitrarily many of these),
%%% we need some way of communicating the names of the variables holding
%%% the current version of the cost and rule tuples between invocations of the
%%% generation routines.
%%%
%%% Currently, this is done by
%%%   - Passing the initial names as arguments
%%%   - Using `eburg_util:gensym' internally to generate new names
%%%   - Returning a tuple of the final names
%%%
%%% The relevant procedures are:
%%%   - `emit_body', which handles communication between the code for
%%%      different rules of a single operator
%%%   - `emit_record' and `emit_rule', which handle the code for a single rule

-spec(emit_clause_body/2 :: ([#rule{}],#eburg{}) -> ok).
%% @doc Prints the code for a single clause of the case statement in
%% `burm_state'.
emit_clause_body(Rs, St) ->
    emit_body("{BurmFC, BurmFR} = {~s, ~s}",
              fun emit_rule/4,
              Rs, St, "BurmIC", "BurmIR").


-spec(emit_body/6 :: (string(),fun(),[#rule{}],#eburg{},
                                  string(),string()) -> ok).
%% @doc Shared parts of `emit_clause_body' and `emit_closure_body'.
emit_body(Final, Next, [R|Rs], St, CurC, CurR) ->
    e("%% ~s", [unparse_rule_short(R)]),
    {NewC, NewR} = Next(R, St, CurC, CurR),
    e(","),
    emit_body(Final, Next, Rs, St, NewC, NewR);
emit_body(Final, _Next, [], _St, CurC, CurR) ->
    e(Final, [CurC, CurR]).


%%% Tree pattern matching and cost computation (c.f. (1) and (2) above) have
%%% been combined into a single test of rule applicability which inspects only
%%% the childrens' cost vectors with matching being done implicitly.
%%% Assume we are checking the rule
%%%
%%%   quux <- FOO(bar, baz)
%%%
%%% against the current node. Firstly, the current node's operator has to match
%%% FOO; this is ensured by the pattern part of the case clause.
%%% Secondly, it must be possible to reduce the left child to bar and the right
%%% child to baz. Since all elements of both the rule and cost vectors are
%%% initialized to a Very Large Integer, if we accept that no combination of
%%% rule applications will ever add up to a value as large as or larger than
%%% this, we can match the children by simply adding their cost vector entries
%%% for bar and baz respectively.
%%%
%%% `gen_cost' and `emit_record' implement this.

-spec(emit_rule/4 :: (#rule{},#eburg{},string(),string()) ->
             {string(),string()}).
%% @doc Returns the names of the variables holding the latest cost and rule
%% vectors after printing code for handling (matching & recording) a single
%% rule.
emit_rule(R = #rule{rhs=#pattern{kids=Kids}}, St, CurC, CurR) ->
    B0 = gensym("Base"),
    e("begin"),
    e("    ~s = ~s,", [B0, gen_cost(Kids)]),
    {NewC,NewR} = emit_record(R, St, CurC, CurR, B0),
    e("end"),
    {NewC,NewR}.


-spec(gen_cost/1 :: ([atom()]) -> string()).
%% @doc Returns code to sum the costs of deriving the nonterminals in `Kids'.
gen_cost([]) ->
    "0";
gen_cost(Kids) ->
    mkcode(sum,
           "?burm_cost(?~s, lists:nth(~p, kids(BurmNode)))",
           enumerate(Kids)).


-spec(emit_record/5 :: (#rule{},#eburg{},string(),string(),string()) ->
             {string(),string()}).
%% @doc prints the code for updating `CurC' and `CurR' according to `Rule'.
%% We have three cases to consider:
%%   - `Rule' is not applicable (too expensive)
%%   - `Rule' is applicable, and its LHS has no closure function
%%   - `Rule' is applicable, and its LHS does have a closure function
%% All of which have to result in the final rule and cost vectors residing
%% in the same variables, whose names are then returned to the caller.
emit_record(#rule{number=N,lhs=Nt,cost=Cost}, St, C0, R0, B0) ->
    RC = concat([Cost]), % ensure it's a string
    %% Fresh variable names
    B1 = gensym("Base"),
    C1 = gensym("Cost"),
    R1 = gensym("Rule"),
    %% Emit code
    e("~s = ~s + ~s,", [B1, B0, RC]),
    e("case ~s < element(?~p, ~s) of", [B1, Nt, C0]),
    e("    true ->"),
    e("        ~s = setelement(?~p, ~s, ~s),", [C1, Nt, C0, B1]),
    e("        ~s = burm_setrule(?~p, ~s, ~p),",
        [R1, Nt, R0, irn2prn(Nt, N, St)]),
    case has_closure(Nt, St) of
        false ->
            {NewC,NewR} = {C1,R1},
            e("{~s, ~s};", [C1, R1]);
        true ->
            C2 = gensym("Cost"),
            R2 = gensym("Rule"),
            {NewC,NewR} = {C2,R2},
            e("{~s, ~s} = burm_closure_~s(BurmNode, ~s, ~s, ~s);",
                [C2, R2, Nt, C1, R1, B1])
    end,
    e("    false ->"),
    e("        {~s, ~s} = {~s, ~s}", [NewC, NewR, C0, R0]),
    e("end"),
    %% Return new variable names
    {NewC,NewR}.


%%% Each `burm_closure_*' function is much like a single clause in the case
%%% statement in `burm_state'.

-spec(emit_closures/1 :: (#eburg{}) -> ok).
%% @doc Prints one closure routine for every nonterminal which has chainrules.
emit_closures(St) ->
    emitcode2(blank,
              fun({Nt, Rs}) ->
                      e("burm_closure_~s(BurmNode, BurmIC, BurmIR, BurmIB) ->",
                        [Nt]),
                      emit_closure_body(Rs, St)
              end,
             [{Nt,Crules} || {Nt,Crules} <- St#eburg.crules, Crules =/= []]).


-spec(emit_closure_body/2 :: ([#rule{}],#eburg{}) -> ok).
%% @doc Prints the body of a single closure routine.
emit_closure_body(Rs, St0) ->
    emit_body("{~s, ~s}.",
              fun(R, St, CurC, CurR) ->
                      emit_record(R, St, CurC, CurR, "BurmIB")
              end,
              Rs, St0, "BurmIC", "BurmIR").


%%%_ , Memoization support

-spec(emit_is_tainted/1 :: (#eburg{}) -> ok).
%% @doc Emits a table indicating which operators have dynamic rules.
emit_is_tainted(St) ->
    Args = [{Op,is_tainted(Op, St)} || Op <- St#eburg.ops ],
    emitcode(pfunc, "burm_is_tainted(~p) -> ~p", Args),
    e("burm_is_tainted(_) -> burm_panic(noop).").


-spec(emit_dyncost/1 :: (#eburg{}) -> ok).
%% @doc Emits a function which evaluates any dynamic cost expressions occuring
%% in the rules of an operator in the context of the current node.
emit_dyncost(St) ->
    Args = [{Op,gen_dyncost(Op, St)} ||
               Op <- St#eburg.ops, is_tainted(Op, St)],
    emitcode(pfunc, "burm_dyncost(~p, BurmNode) -> ~s", Args),
    e("burm_dyncost(_, _) -> burm_panic(dyncost).").


-spec(gen_dyncost/2 :: (atom(),#eburg{}) -> string()).
%% @doc Returns code for a tuple whose elements are the dynamic cost
%% expressions occuring in rules which may be called when labeling a node whose
%% root operator is `Op'.
gen_dyncost(Op, St) -> mkcode(tuple, "~s", sget(Op, taints, St)).


%%%_. Reducer

-spec(emit_reducer/1 :: (#eburg{}) -> ok).
%%@doc Emit runtime support routines for eburg-generated reducers.
emit_reducer(St) ->
    emit_nts(St),
    emit_action(St),
    emit_is_chainrule(St),
    emit_string(St).


-spec(emit_nts/1 :: (#eburg{}) -> ok).
%% @doc Emits `burm_nts', which takes an IRN and returns the INNs of the
%% nonterminals occuring in that rule.
emit_nts(St) ->
    emitcode(func,
           "burm_nts(~p) -> ~s",
           [{R#rule.number,gen_nts(R)} || R <- St#eburg.rules]).


-spec(gen_nts/1 :: (#rule{}) -> string()).
%% @doc Returns code for a list containing the INNs of the nonterminals on the
%% RHS of `R' in the order in which they appear on the RHS of `R'.
gen_nts(#rule{rhs=#pattern{kids=Kids}}) -> gen_nts_(Kids);
gen_nts(#rule{rhs=Nt})                  -> gen_nts_([Nt]).
gen_nts_(Nts)                           -> mkcode(list, "?~p", Nts).


-spec(emit_action/1 :: (#eburg{}) -> ok).
%% @doc Prints code for executing the semantic actions encapsulated in a
%% separate routine.
emit_action(St) ->
    e("burm_action(BurmNode, BurmReducedKids, BurmRule) ->"),
    e("    case BurmRule of"),
    emit_actions(St),
    e("    end.").


-spec(emit_actions/1 :: (#eburg{}) -> ok).
%% @doc Prints the body of the case statement in `burm_action'.
emit_actions(St) ->
    Args = [{R#rule.number,R#rule.action} || R <- St#eburg.rules],
    emitcode(cbody, "~p -> ~s", Args).


-spec(emit_is_chainrule/1 :: (#eburg{}) -> ok).
%% @doc Yes.
emit_is_chainrule(St) ->
    emitcode(func, "burm_is_chainrule(~p) -> ~p",
           [{R#rule.number,is_chainrule(R)} || R <- St#eburg.rules]).

is_chainrule(#rule{rhs=Nt})  when is_atom(Nt)             -> true;
is_chainrule(#rule{rhs=Pat}) when is_record(Pat, pattern) -> false.


-spec(emit_string/1 :: (#eburg{}) -> ok).
%% @doc Emits `burm_string', which maps IRNs and INNs to strings.
emit_string(St) ->
    %% Rule names
    emitcode(pfunc, "burm_string({rule, ~p}) -> ~p",
           [{R#rule.number, unparse_rule_short(R)} || R <- St#eburg.rules]),
    %% Nonterminal names
    emitcode(func, "burm_string({nt, ~p}) -> ~p",
           [{sget(Nt,inn,St),atom_to_list(Nt)} || Nt <- St#eburg.nts]).


%%%_. Emacs
%%% Local Variables:
%%% allout-layout: t
%%% End:
