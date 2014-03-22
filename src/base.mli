
(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Base Definitions} *)

(** {2 Signature for symbols} *)

module type CONST = sig
  type t

  val equal : t -> t -> bool
  val hash : t -> int
  val to_string : t -> string
  val of_string : string -> t

  val query : t
    (** Special symbol, that will never occur in any user-defined
        clause or term. For strings, this may be the empty string "". *)
end

(** {2 Terms, Clauses, Substitutions, Indexes} *)

module type S = sig
  module Const : CONST

  type const = Const.t

  val set_debug : bool -> unit

  (** {2 Terms} *)

  module T : sig
    type t = private
    | Var of int
    | Apply of const * t array

    val mk_var : int -> t
    val mk_const : const -> t
    val mk_apply : const -> t array -> t
    val mk_apply_l : const -> t list -> t

    val is_var : t -> bool
    val is_apply : t -> bool
    val is_const : t -> bool

    val eq : t -> t -> bool
    val hash : t -> int
    val hash_novar : t -> int

    val ground : t -> bool
    val vars : t -> int list
    val max_var : t -> int    (** max var, or 0 if ground *)
    val head_symbol : t -> const

    val to_string : t -> string
    val pp : out_channel -> t -> unit
    val fmt : Format.formatter -> t -> unit

    val pp_tuple : out_channel -> t list -> unit

    module Tbl : Hashtbl.S with type key = t
  end

  (** {2 Literals} *)

  module Lit : sig
    type aggregate = {
      left : T.t;
      constructor : const;
      var : T.t;
      guard : T.t;
    } (* aggregate: ag_left = ag_constructor set
        where set is the set of bindings to ag_var
        that satisfy ag_guard *)

    type t =
    | LitPos of T.t
    | LitNeg of T.t
    | LitAggr of aggregate

    val mk_pos : T.t -> t
    val mk_neg : T.t -> t
    val mk : bool -> T.t -> t

    val mk_aggr : left:T.t -> constructor:const -> var:T.t -> guard:T.t -> t

    val eq : t -> t -> bool
    val hash : t -> int
    val hash_novar : t -> int

    val to_term : t -> T.t
    val fmap : (T.t -> T.t) -> t -> t

    val to_string : t -> string
    val pp : out_channel -> t -> unit
    val fmt : Format.formatter -> t -> unit
  end

  (** {2 Clauses} *)

  module C : sig
    type t = private {
      head : T.t;
      body : Lit.t list;
    }

    exception Unsafe

    val mk_clause : T.t -> Lit.t list -> t
    val mk_fact : T.t -> t

    val set_head : t -> T.t -> t
    val set_body : t -> Lit.t list -> t

    val eq : t -> t -> bool
    val hash : t -> int
    val hash_novar : t -> int

    val head_symbol : t -> const
    val max_var : t -> int
    val fmap : (T.t -> T.t) -> t -> t

    val to_string : t -> string
    val pp : out_channel -> t -> unit
    val fmt : Format.formatter -> t -> unit

    module Tbl : Hashtbl.S with type key = t
  end

  (** {2 Substs} *)

  (** This module is used for variable bindings. *)

  module Subst : sig
    type t
    type scope = int
    type renaming

    val empty : t
      (** Empty subst *)
    
    val bind : t -> T.t -> scope -> T.t -> scope -> t
      (** Bind a variable,scope to a term,scope *)

    val deref : t -> T.t -> scope -> T.t * scope
      (** While the term is a variable bound in subst, follow its binding.
          Returns the final term and scope *)

    val create_renaming : unit -> renaming

    val reset_renaming : renaming -> unit

    val rename : renaming:renaming -> T.t -> scope -> T.t
      (** Rename the given variable into a variable that is unique
          within variables known to the given [renaming] *)

    val eval : t -> renaming:renaming -> T.t -> scope -> T.t
      (** Apply the substitution to the term. Free variables are renamed
          using [renaming] *)

    val eval_lit : t -> renaming:renaming -> Lit.t -> scope -> Lit.t

    val eval_lits : t -> renaming:renaming -> Lit.t list -> scope -> Lit.t list

    val eval_clause : t -> renaming:renaming -> C.t -> scope -> C.t
  end

  (** {2 Unification, matching...} *)

  type scope = Subst.scope

  module Unif : sig
    exception Fail


    (** For {!unify} and {!match_}, the optional parameter [oc] is used to
        enable or disable occur-check. It is disabled by default. *)

    val unify : ?oc:bool -> ?subst:Subst.t -> T.t -> scope -> T.t -> scope -> Subst.t
      (** Unify the two terms.
          @raise UnifFail if it fails *)

    val match_ : ?oc:bool -> ?subst:Subst.t -> T.t -> scope -> T.t -> scope -> Subst.t
      (** [match_ a sa b sb] matches the pattern [a] in scope [sa] with term
          [b] in scope [sb].
          @raise UnifFail if it fails *)

    val alpha_equiv : ?subst:Subst.t -> T.t -> scope -> T.t -> scope -> Subst.t
      (** Test for alpha equivalence.
          @raise UnifFail if it fails *)

    val are_alpha_equiv : T.t -> T.t -> bool
      (** Special version of [alpha_equiv], using distinct scopes for the two
          terms to test, and discarding the result *)

    val clause_are_alpha_equiv : C.t -> C.t -> bool
      (** Alpha equivalence of clauses. *)
  end

  (** {2 Special built-in functions}
  The built-in functions are symbols that have a special {b meaning}. The
  meaning is given by a set of OCaml functions that can evaluate applications
  of the function symbol to arguments.

  For instance, [sum] is a special built-in function that tries to add its
  arguments if those are constants.

  {b Note} that a constant will never be interpreted.
  *)

  module BuiltinFun : sig
    type t = T.t -> T.t option

    type map
      (** Map symbols to builtin functions. Every symbol can only have at
          most one built-in function. *)

    val create : unit -> map

    val add : map -> Const.t -> t -> map
      (** Interpret the given constant by the given function. The function
          can assume that any term is it given as a parameter has the
          constant as head. *)

    val add_list : map -> (Const.t * t) list -> map

    val interpreted : map -> Const.t -> bool
      (** Is the constant interpreted by a built-in function? *)

    val eval : map -> T.t -> T.t
      (** Evaluate the term at root *)
  end

  (** The following hashtables use alpha-equivalence checking instead of
      regular, syntactic equality *)

  module TVariantTbl : PersistentHashtbl.S with type key = T.t
  module CVariantTbl : PersistentHashtbl.S with type key = C.t

  (** {2 Index}
  An index is a specialized data structured that is used to efficiently
  store and retrieve data by a key, where the key is a term. Retrieval
  involves finding all data associated with terms that match,
  or unify with, a given term. *)

  module Index(Data : Hashtbl.HashedType) : sig
    type t
      (** A set of term->data bindings, for efficient retrieval by unification *)

    val empty : unit -> t
      (** new, empty index *)

    val copy : t -> t
      (** Full copy of the index *)

    val add : t -> T.t -> Data.t -> t
      (** Add the term->data binding. *)

    val remove : t -> T.t -> Data.t -> t
      (** Remove the term->data binding. *)

    val generalizations : ?oc:bool -> t -> scope -> T.t -> scope ->
                          (Data.t -> Subst.t -> unit) -> unit
      (** Retrieve data associated with terms that are a generalization
          of the given query term *)

    val unify : ?oc:bool -> t -> scope -> T.t -> scope ->
                (Data.t -> Subst.t -> unit) -> unit
      (** Retrieve data associated with terms that unify with the given
          query term *)

    val iter : t -> (T.t -> Data.t -> unit) -> unit
      (** Iterate on bindings *)

    val size : t -> int
      (** Number of bindings *)
  end

  (** {2 Rewriting}
  Rewriting consists in having a set of {b rules}, oriented from left to right,
  that we will write [l -> r] (say "l rewrites to r"). Any term t that l matches
  is {b rewritten} into r by replacing it by sigma(r), where sigma(l) = t.
  *)

  module Rewriting : sig
    type rule = T.t * T.t

    type t
      (** A rewriting system. It is basically a mutable set of rewrite rules. *)

    val create : unit -> t
      (** New rewriting system *)

    val copy : t -> t
      (** Copy the rewriting system *)

    val add : t -> rule -> unit
      (** Add a rule to the system *)

    val add_list : t -> rule list -> unit

    val to_list : t -> rule list
      (** List of rules *)

    val rewrite_root : t -> T.t -> T.t
      (** rewrite the term, but only its root. Subterms are not rewritten
          at all. *)

    val rewrite : t -> T.t -> T.t
      (** Normalize the term recursively. The returned type cannot be rewritten
          any further, assuming the rewriting system is {b terminating} *)
  end
end

(** {2 Implementation} *)

module Make(C : CONST) : S with module Const = C

(** {2 Parsing} *)

module type PARSABLE_CONST = sig
  type t

  val of_string : string -> t
  val of_int : int -> t
end

module type PARSE = sig
  type term
  type lit
  type clause

  type name_ctx = (string, term) Hashtbl.t

  val create_ctx : unit -> name_ctx

  val term_of_ast : ctx:name_ctx -> Ast.term -> term
  val lit_of_ast : ctx:name_ctx -> Ast.literal -> lit
  val clause_of_ast : ?ctx:name_ctx -> Ast.clause -> clause
  val clauses_of_ast : ?ctx:name_ctx -> Ast.clause list -> clause list

  val parse_chan : in_channel -> [`Ok of clause list | `Error of string]
  val parse_file : string -> [`Ok of clause list | `Error of string]
  val parse_string : string -> [`Ok of clause list | `Error of string]

  val clause_of_string : string -> clause
    (** Parse a clause from a string, or fail. Useful shortcut to define
        properties of relations without building terms by hand.
        @raise Failure if the string is not a valid clause *)

  val term_of_string : string -> term
    (** @raise Failure if the string is not a valid term *)
end

module MakeParse(C : PARSABLE_CONST)(TD : S with type Const.t = C.t) :
  PARSE with type term = TD.T.t and type lit = TD.Lit.t and type clause = TD.C.t

(** {2 Default Implementation with Strings} *)

type const =
  | Int of int
  | String of string

module Default : sig
  include S with type Const.t = const

  include PARSE with type term = T.t and type lit = Lit.t and type clause = C.t
end