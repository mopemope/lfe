%% Copyright (c) 2008 Robert Virding. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.

%% File    : lfe_shell.erl
%% Author  : Robert Virding
%% Purpose : A simple Lisp Flavoured Erlang shell.

-module(lfe_shell).

-export([start/0,start/1,server/0,server/1]).

-import(lfe_lib, [new_env/0,add_env/2,
		  add_vbinding/3,add_vbindings/2,vbinding/2,
		  fetch_vbinding/2,update_vbinding/3,
		  add_fbinding/4,add_fbindings/3,fbinding/3,add_ibinding/5,
		  gbinding/3,add_mbinding/3]).

-import(orddict, [store/3,find/2]).
-import(ordsets, [add_element/2]).
-import(lists, [map/2,foreach/2,foldl/3]).

%% -compile([export_all]).

start() ->
    spawn(fun () -> server(default) end).

start(P) ->
    spawn(fun () -> server(P) end).

server() -> server(default).

server(_) ->
    io:fwrite("LFE Shell V~s (abort with ^G)\n",
	      [erlang:system_info(version)]),
    %% Add default nil bindings to predefined shell variables.
    Env0 = add_shell_macros(new_env()),
    Env1 = add_shell_vars(Env0),
    server_loop(Env1, Env1).

server_loop(Env0, BaseEnv) ->
    Env = try
	      %% Read the form
	      lfe_io:print('>'),
	      Form = lfe_io:read(),
	      Env1 = update_vbinding('-', Form, Env0),
	      %% Macro expand and evaluate it.
	      {Value,Env2} = eval_form(Form, Env1, BaseEnv),
	      %% Print the result.
	      lfe_io:prettyprint(Value), io:nl(),
	      %% Update bindings.
	      Env3 = update_shell_vars(Form, Value, Env2),
	      %% lfe_io:prettyprint({Env1,Env2}), io:nl(),
	      Env3
	  catch
	      %% Very naive error handling, just catch, report and
	      %% ignore whole caboodle.
	      Class:Error ->
		  %% Use the erlang shell's error reporting, but LFE
		  %% prettyprint data.
		  St = erlang:get_stacktrace(),
		  %% lfe_io:print({'EXIT',Class,Error,St}), io:nl(),
		  Sf = fun (M, _F, _A) ->
			       (M == shell)
				   or (M == erl_eval)
				   or (M == lfe_shell)
		       end,
		  %% Can't use this as format_exception *knows* Erlang
		  %% syntax!
		  %% Ff = fun (T, I) -> lfe_io:prettyprint1(T, I) end,
		  Ff = fun (T, I) -> io_lib:fwrite("~.*p", [I,T]) end,
		  Cs = lib:format_exception(1, Class, Error, St, Sf, Ff),
		  io:put_chars(Cs),
		  io:nl(),
		  Env0
	  end,
    server_loop(Env, BaseEnv).

add_shell_vars(Env) ->
    %% Add default shell expression variables.
    foldl(fun (Symb, E) -> add_vbinding(Symb, [], E) end, Env,
	  ['+','++','+++','-','*','**','***']).

update_shell_vars(Form, Value, Env) ->
    foldl(fun ({Symb,Val}, E) -> update_vbinding(Symb, Val, E) end,
	  Env,
	  [{'+++',fetch_vbinding('++', Env)},
	   {'++',fetch_vbinding('+', Env)},
	   {'+',Form},
	   {'***',fetch_vbinding('**', Env)},
	   {'**',fetch_vbinding('*', Env)},
	   {'*',Value}]).    

add_shell_macros(Env) ->
    foldl(fun ({Symb,Macro}, E) -> add_mbinding(Symb, Macro, E) end,
	  Env,
	  [{ec,['syntax-rules',[as,[call,[quote,c],[quote,c]|as]]]},
	   {m,['syntax-rules',[fs,[call,[quote,c],[quote,m]|fs]]]}]).

%% eval_form(Form, EvalEnv, BaseEnv) -> {Value,Env}.

eval_form(Form, Env0, Benv) ->
    %% lfe_io:prettyprint({Form,Env0}),
    %% io:fwrite("ef: ~p\n", [{Form,Env0}]),
    Eform = lfe_macro:expand_form(Form, Env0),
    case eval_internal(Eform, Env0, Benv) of
	{yes,Value,Env1} -> {Value,Env1};
	no ->
	    %% Normal evaluation of form.
	    {lfe_eval:eval(Eform, Env0),Env0}
    end.


%% eval_internal(Form, EvalEnv, BaseEnv) -> {yes,Value,Env} | no.
%%  Check for and evaluate internal functions. These all evaluate
%%  their arguments.

eval_internal([slurp|Args], Eenv, Benv) ->	%Slurp in a file
    slurp(Args, Eenv, Benv);
eval_internal([unslurp|_], _, Benv) ->		%Forget everything
    {yes,ok,Benv};
eval_internal([c|Args], Eenv, Benv) ->		%Compile a file
    c(Args, Eenv, Benv);
eval_internal([l|Files], Eenv, _) ->		%Load modules
    Rs = map(fun (E) ->
		     Mod = lfe_eval:eval(E, Eenv),
		     code:purge(Mod),
		     code:load_file(Mod)
	     end, Files),
    {yes,Rs,Eenv};
eval_internal([m|Mods], Eenv, _) ->
    case Mods of
	[M] -> c:m(lfe_eval:eval(M, Eenv));
	[] -> c:m()
    end;
eval_internal(_, _, _) -> no.			%Not an internal function.

%% c(Args, EvalEnv, BaseEnv) -> {yes,
%%  Compile and load file.

c([F], Eenv, Benv) ->
    c([F,[]], Eenv, Benv);
c([F,Os], Eenv, _) ->
    Name = lfe_eval:eval(F, Eenv),		%Evaluate arguments
    Opts = lfe_eval:eval(Os, Eenv),
    case lfe_comp:file(Name, Opts) of
	{ok,Mod,_} ->
	    Base = filename:basename(Name, ".lfe"),
	    code:purge(Mod),
	    R = code:load_abs(Base),
	    {yes,R,Eenv};
	Other -> {yes,Other,Eenv}
    end.

%% slurp(File, EvalEnv, BaseEnv) -> {yes,{mod,Mod},Env}.
%%  Load in a file making all functions available. The module is
%%  loaded in an empty environment and that environment is finally
%%  added to the standard base environment.

-record(slurp, {mod,imps=[]}).			%For slurping
    
slurp([File], Eenv, Benv) ->
    Name = lfe_eval:eval(File, Eenv),		%Get file name
    Fs0 = lfe_io:parse_file(Name),
    St0 = #slurp{mod='-no-mod-',imps=[]},
    {Fs1,Fenv0} = lfe_macro:expand_forms(Fs0, new_env()),
    {Fbs,St1} = lfe_lib:proc_forms(fun collect_form/3, Fs1, St0),
    %% Add imports to environment.
    Fenv1 = foldl(fun ({M,Is}, Env) ->
			  foldl(fun ({{F,A},R}, E) ->
					add_ibinding(M, F, A, R, E)
				end, Env, Is)
		  end, Fenv0, St1#slurp.imps),
    %% Get a new environment with all functions defined.
    Fenv2 = lfe_eval:fletrec_env(Fbs, Fenv1),
    {yes,{ok,St1#slurp.mod},add_env(Fenv2, Benv)}.

collect_form(['define-module',Mod|Mdef], _, St0) when is_atom(Mod) ->
    St1 = collect_mdef(Mdef, St0),
    {[],St1#slurp{mod=Mod}};
collect_form([define,[F|As]|Body], _, St) when is_atom(F) ->
    {[{F,length(As),[lambda,As|Body]}],St};
collect_form([define,F,[lambda,As|_]=Lambda], _, St) when is_atom(F) ->
    {[{F,length(As),Lambda}],St};
collect_form([define,F,['match-lambda',[Pats|_]|_]=Match], _, St)
  when is_atom(F) ->
    {[{F,length(Pats),Match}],St};
collect_form(_, _, _) ->
    exit(unknown_form).

collect_mdef([[import|Imps]|Mdef], St) ->
    collect_mdef(Mdef, collect_imps(Imps, St));
collect_mdef([_|Mdef], St) ->
    %% Ignore everything else.
    collect_mdef(Mdef, St);
collect_mdef([], St) -> St.

collect_imps([['from',Mod|Fs]|Is], St0) when is_atom(Mod) ->
    St1 = collect_imp(fun ([F,A], Imps) when is_atom(F), is_integer(A) ->
			      store({F,A}, F, Imps)
		      end, Mod, St0, Fs),
    collect_imps(Is, St1);
collect_imps([['rename',Mod|Rs]|Is], St0) when is_atom(Mod) ->
    St1 = collect_imp(fun ([[F,A],R], Imps)
			  when is_atom(F), is_integer(A), is_atom(R) ->
			      store({F,A}, R, Imps)
		      end, Mod, St0, Rs),
    collect_imps(Is, St1);
collect_imps([], St) -> St.

collect_imp(Fun, Mod, St, Fs) ->
    Imps0 = safe_fetch(Mod, St#slurp.imps, []),
    Imps1 = foldl(Fun, Imps0, Fs),
    St#slurp{imps=store(Mod, Imps1, St#slurp.imps)}.

%% safe_fetch(Key, Dict, Default) -> Value.

safe_fetch(Key, D, Def) ->
    case find(Key, D) of
	{ok,Val} -> Val;
	error -> Def
    end.

%% (define-syntax safe_fetch
%%   (syntax-rules
%%     ((key d def)
%%      (case (find key d)
%%        ((tuple 'ok val) val)
%%        ('error def))))))