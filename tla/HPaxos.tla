------------------------------- MODULE HPaxos -------------------------------
EXTENDS Naturals, FiniteSets, Functions

-----------------------------------------------------------------------------
CONSTANT LastBallot
ASSUME LastBallot \in Nat

Ballot == Nat

CONSTANT Value
ASSUME ValueNotEmpty == Value # {}

-----------------------------------------------------------------------------
CONSTANTS SafeAcceptor,
          FakeAcceptor,
          ByzQuorum,
          Learner

Acceptor == SafeAcceptor \cup FakeAcceptor

ASSUME AcceptorAssumption ==
    /\ SafeAcceptor \cap FakeAcceptor = {}
\*    /\ Acceptor \cap Learner = {}

ASSUME BQAssumption ==
    /\ SafeAcceptor \in ByzQuorum
    /\ \A Q \in ByzQuorum : Q \subseteq Acceptor

-----------------------------------------------------------------------------
(* Learner graph *)

CONSTANT TrustLive
ASSUME TrustLiveAssumption ==
    TrustLive \in SUBSET [lr : Learner, q : ByzQuorum]

CONSTANT TrustSafe
ASSUME TrustSafeAssumption ==
    TrustSafe \in SUBSET [from : Learner, to : Learner, q : ByzQuorum]

ASSUME LearnerGraphAssumptionSymmetry ==
    \A E \in TrustSafe :
        [from |-> E.to, to |-> E.from, q |-> E.q] \in TrustSafe

ASSUME LearnerGraphAssumptionTransitivity ==
    \A E1, E2 \in TrustSafe :
        E1.q = E2.q /\ E1.to = E2.from =>
        [from |-> E1.from, to |-> E2.to, q |-> E1.q] \in TrustSafe

ASSUME LearnerGraphAssumptionClosure ==
    \A E \in TrustSafe : \A Q \in ByzQuorum :
        E.q \subseteq Q =>
        [from |-> E.from, to |-> E.to, q |-> Q] \in TrustSafe

ASSUME LearnerGraphAssumptionValidity ==
    \A E \in TrustSafe : \A Q1, Q2 \in ByzQuorum :
        [lr |-> E.from, q |-> Q1] \in TrustLive /\
        [lr |-> E.to, q |-> Q2] \in TrustLive =>
        \E N \in E.q : N \in Q1 /\ N \in Q2

(* Entanglement relation *)
Ent == { LL \in Learner \X Learner :
         [from |-> LL[1], to |-> LL[2], q |-> SafeAcceptor] \in TrustSafe }

-----------------------------------------------------------------------------
(* Messages *)

CONSTANT MaxRefCardinality
ASSUME MaxRefCardinalityAssumption ==
    /\ MaxRefCardinality \in Nat
    /\ MaxRefCardinality >= 1

\*RefCardinality == Nat
RefCardinality == 1..MaxRefCardinality

FINSUBSET(S, R) == { Range(seq) : seq \in [R -> S] }
\*FINSUBSET(S, K) == { Range(seq) : seq \in [1..K -> S] }
\*FINSUBSET(S, R) == UNION { {Range(seq) : seq \in [1..K -> S]} : K \in R }

MessageRec0 ==
    [ type : {"1a"}, bal : Ballot, ref : {{}} ]

MessageRec1(M, n) ==
    M \cup
    [ type : {"1b"},
      acc : Acceptor,
      ref : FINSUBSET(M, RefCardinality) ] \cup
    [ type : {"2a"},
      lrn : Learner,
      acc : Acceptor,
      ref : FINSUBSET(M, RefCardinality) ]

MessageRec[n \in Nat] ==
    IF n = 0
    THEN MessageRec0
    ELSE MessageRec1(MessageRec[n-1], n)

CONSTANT MaxMessageDepth
ASSUME MaxMessageDepth \in Nat

MessageDepthRange == Nat

Message == UNION { MessageRec[n] : n \in MessageDepthRange }

-----------------------------------------------------------------------------
(* Transitive references *)

\* Bounded transitive references
TranBound0 == [m \in Message |-> {m}]
TranBound1(tr, n) ==
    [m \in Message |-> {m} \cup UNION {tr[r] : r \in m.ref}]

TranBound[n \in Nat] ==
    IF n = 0
    THEN TranBound0
    ELSE TranBound1(TranBound[n-1], n)

\* Countable transitive references
TranDepthRange == MessageDepthRange

Tran(m) == UNION {TranBound[n][m] : n \in TranDepthRange}

-----------------------------------------------------------------------------
(* Algorithm specification *)

VARIABLES msgs,
          known_msgs,
          recent_msgs,
          2a_lrn_loop,
          processed_lrns,
          decision,
          BVal \* TODO comment

Get1a(m) ==
    { x \in Tran(m) :
        /\ x.type = "1a"
        /\ \A y \in Tran(m) :
            y.type = "1a" => y.bal <= x.bal }
\* Invariant: x \in Get1a(m) /\ y \in Get1a(m) => x = y
\* TODO: totality for 1b, 2a messages. Required invariant:
\*   each well-formed 1b references a 1a.

B(m, bal) == \E x \in Get1a(m) : bal = x.bal

V(m, val) == \E x \in Get1a(m) : val = BVal[x.bal]

\* Maximal ballot number of any messages known to acceptor a
MaxBal(a, mbal) ==
    /\ \E m \in known_msgs[a] : B(m, mbal)
    /\ \A x \in known_msgs[a] :
        \A b \in Ballot : B(x, b) => b =< mbal

SameBallot(x, y) ==
    \A b \in Ballot : B(x, b) <=> B(y, b)

\* The acceptor is _caught_ in a message x if the transitive references of x
\* include evidence such as two messages both signed by the acceptor, in which
\* neither is featured in the other's transitive references.
CaughtMsg(x) ==
    { m \in Tran(x) :
        /\ m.type # "1a"
        /\ \E m1 \in Tran(x) :
            /\ m1.type # "1a"
            /\ m.acc = m1.acc
            /\ m \notin Tran(m1)
            /\ m1 \notin Tran(m) }

Caught(x) == { m.acc : m \in CaughtMsg(x) }

\* Connected
ConByQuorum(a, b, x, S) ==
    /\ [from |-> a, to |-> b, q |-> S] \in TrustSafe
    /\ S \cap Caught(x) = {}

Con(a, x) ==
    { b \in Learner : \E S \in ByzQuorum : ConByQuorum(a, b, x, S) }

\* 2a-message is _buried_ if there exists a quorum of acceptors that have seen
\* 2a-messages with different values, the same learner, and higher ballot
\* numbers.
Buried(x, y) ==
    LET Q == { m \in Tran(y) :
                \E z \in Tran(m) :
                    /\ z.type = "2a"
                    /\ z.lrn = x.lrn
                    /\ \A bx, bz \in Ballot :
                        B(x, bx) /\ B(z, bz) => bx < bz
                    /\ \A vx, vz \in Value :
                        V(x, vx) /\ V(z, vz) => vx # vz }
    IN [lr |-> x.lrn, q |-> { m.acc : m \in Q }] \in TrustLive

\* Connected 2a messages
Con2as(l, x) ==
    { m \in Tran(x) :
        /\ m.type = "2a"
        /\ m.acc = x.acc
        /\ ~Buried(m, x)
        /\ m.lrn \in Con(l, x) }

\* Fresh 1b messages
Fresh(l, x) == \* x : 1b
    \A m \in Con2as(l, x) : \A v \in Value : V(x, v) <=> V(m, v)

\* Quorum of messages referenced by 2a
q(x) ==
    LET Q == { m \in Tran(x) :
                /\ m.type = "1b"
                /\ Fresh(x.lrn, m)
                /\ \A b \in Ballot : B(m, b) <=> B(x, b) }
    IN { m.acc : m \in Q }

WellFormed(m) ==
    /\ m \in Message
    /\ \E b \in Ballot : B(m, b) \* TODO prove it
    /\ m.type = "1b" =>
        \A y \in Tran(m) :
            m # y /\ SameBallot(m, y) => y.type = "1a"
    /\ m.type = "2a" =>
        /\ [lr |-> m.lrn, q |-> q(m)] \in TrustLive

vars == << msgs, known_msgs, recent_msgs, 2a_lrn_loop, processed_lrns, decision, BVal >>

Init ==
    /\ msgs = {}
    /\ known_msgs = [x \in Acceptor \cup Learner |-> {}]
    /\ recent_msgs = [a \in Acceptor \cup Learner |-> {}]
    /\ 2a_lrn_loop = [a \in Acceptor |-> FALSE]
    /\ processed_lrns = [a \in Acceptor |-> {}]
    /\ decision = [lb \in Learner \X Ballot |-> {}]
    /\ BVal \in [Ballot -> Value]

Send(m) == msgs' = msgs \cup {m}

Proper(a, m) == \A r \in m.ref : r \in known_msgs[a]

Recv(a, m) ==
    /\ WellFormed(m)
    /\ Proper(a, m)
    /\ known_msgs' = [known_msgs EXCEPT ![a] = known_msgs[a] \cup {m}]

Send1a(b) ==
    /\ Send([type |-> "1a", bal |-> b, ref |-> {}])
    /\ UNCHANGED << known_msgs, recent_msgs, 2a_lrn_loop, processed_lrns, decision >>
    /\ UNCHANGED BVal

Known2a(l, b, v) ==
    { x \in known_msgs[l] :
        /\ x.type = "2a"
        /\ x.lrn = l
        /\ B(x, b)
        /\ V(x, v) }

Process1a(a, m) ==
    LET new1b == [type |-> "1b", acc |-> a, ref |-> recent_msgs[a] \cup {m}] IN
    /\ Recv(a, m)
    /\ m.type = "1a"
    /\ WellFormed(new1b) =>
        /\ Send(new1b)
        /\ recent_msgs' = [recent_msgs EXCEPT ![a] = {new1b}]
    /\ (~WellFormed(new1b)) =>
        /\ recent_msgs' = [recent_msgs EXCEPT ![a] = recent_msgs[a] \cup {m}]
        /\ UNCHANGED msgs
    /\ UNCHANGED << 2a_lrn_loop, processed_lrns, decision >>
    /\ UNCHANGED BVal

Process1b(a, m) ==
    /\ Recv(a, m)
    /\ m.type = "1b"
    /\ recent_msgs' = [recent_msgs EXCEPT ![a] = recent_msgs[a] \cup {m}]
    /\ (\A mb, b \in Ballot : MaxBal(a, mb) /\ B(m, b) => mb <= b) =>
        /\ 2a_lrn_loop' = [2a_lrn_loop EXCEPT ![a] = TRUE]
        /\ processed_lrns' = [processed_lrns EXCEPT ![a] = {}]
    /\ (~(\A mb, b \in Ballot : MaxBal(a, mb) /\ B(m, b) => mb <= b)) =>
        UNCHANGED << 2a_lrn_loop, processed_lrns >>
    /\ UNCHANGED << msgs, decision >>
    /\ UNCHANGED BVal

Process1bLearnerLoopStep(a, lrn) ==
    LET new2a == [type |-> "2a", lrn |-> lrn, acc |-> a, ref |-> recent_msgs[a]] IN
    /\ processed_lrns' =
        [processed_lrns EXCEPT ![a] = processed_lrns[a] \cup {lrn}]
    /\ WellFormed(new2a) =>
        /\ Send(new2a)
        /\ recent_msgs' = [recent_msgs EXCEPT ![a] = {new2a}]
    /\ (~WellFormed(new2a)) =>
        UNCHANGED << msgs, recent_msgs >>
    /\ UNCHANGED << known_msgs, 2a_lrn_loop, decision >>
    /\ UNCHANGED BVal

Process1bLearnerLoopDone(a) ==
    /\ Learner \ processed_lrns[a] = {}
    /\ 2a_lrn_loop' = [2a_lrn_loop EXCEPT ![a] = FALSE]
    /\ UNCHANGED << msgs, known_msgs, recent_msgs, processed_lrns, decision >>
    /\ UNCHANGED BVal

Process1bLearnerLoop(a) ==
    \/ \E lrn \in Learner \ processed_lrns[a] :
        Process1bLearnerLoopStep(a, lrn)
    \/ Process1bLearnerLoopDone(a)

Process2a(a, m) ==
    /\ Recv(a, m)
    /\ m.type = "2a"
    /\ recent_msgs' = [recent_msgs EXCEPT ![a] = recent_msgs[a] \cup {m}]
    /\ UNCHANGED << msgs, 2a_lrn_loop, processed_lrns, decision >>
    /\ UNCHANGED BVal

ProposerSendAction ==
    \E bal \in Ballot : Send1a(bal)

AcceptorProcessAction ==
    \E a \in SafeAcceptor:
        \/ /\ 2a_lrn_loop[a] = FALSE
           /\ \E m \in msgs :
                /\ m \notin known_msgs[a]
                /\ \/ Process1a(a, m)
                   \/ Process1b(a, m)
        \/ /\ 2a_lrn_loop[a] = TRUE
           /\ Process1bLearnerLoop(a)

FakeSend1b(a) ==
    /\ \E fin \in FINSUBSET(msgs, RefCardinality) :
        LET new1b == [type |-> "1b", acc |-> a, ref |-> fin] IN
        /\ WellFormed(new1b)
        /\ Send(new1b)
    /\ UNCHANGED << known_msgs, recent_msgs, 2a_lrn_loop, processed_lrns, decision >>
    /\ UNCHANGED BVal

FakeSend2a(a) ==
    /\ \E fin \in FINSUBSET(msgs, RefCardinality) :
        \E lrn \in Learner :
            LET new2a == [type |-> "2a", lrn |-> lrn, acc |-> a, ref |-> fin] IN
            /\ WellFormed(new2a)
            /\ Send(new2a)
    /\ UNCHANGED << known_msgs, recent_msgs, 2a_lrn_loop, processed_lrns, decision >>
    /\ UNCHANGED BVal

LearnerRecv(l, m) ==
    /\ Recv(l, m)
    /\ UNCHANGED << msgs, recent_msgs, 2a_lrn_loop, processed_lrns, decision >>
    /\ UNCHANGED BVal

ChosenIn(l, b, v) ==
    \E S \in SUBSET Known2a(l, b, v) :
        [lr |-> l, q |-> { m.acc : m \in S }] \in TrustLive

LearnerDecide(l, b, v) ==
    /\ ChosenIn(l, b, v)
    /\ decision' = [decision EXCEPT ![<<l, b>>] = decision[l, b] \cup {v}]
    /\ UNCHANGED << msgs, known_msgs, recent_msgs, 2a_lrn_loop, processed_lrns >>
    /\ UNCHANGED BVal

LearnerAction ==
    \E lrn \in Learner :
        \/ \E m \in msgs :
            LearnerRecv(lrn, m)
        \/ \E bal \in Ballot :
           \E val \in Value :
            LearnerDecide(lrn, bal, val)

FakeAcceptorAction ==
    \E a \in FakeAcceptor :
        \/ FakeSend1b(a)
        \/ FakeSend2a(a)

Next ==
    /\ \/ ProposerSendAction
       \/ AcceptorProcessAction
       \/ LearnerAction
       \/ FakeAcceptorAction

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Safety ==
    \A L1, L2 \in Learner: \A B1, B2 \in Ballot : \A V1, V2 \in Value :
        <<L1, L2>> \in Ent /\
        V1 \in decision[L1, B1] /\ V2 \in decision[L2, B2] =>
        V1 = V2

\* THEOREM SafetyResult == Spec => []Safety

-----------------------------------------------------------------------------
(* Sanity check propositions *)

SanityCheck0 ==
    \A L \in Learner : Cardinality(known_msgs[L]) = 0

SanityCheck1 ==
    \A L \in Learner : \A m1, m2 \in known_msgs[L] :
    \A b1, b2 \in Ballot :
        B(m1, b1) /\ B(m2, b2) => b1 = b2

2aNotSent ==
    \A M \in msgs : M.type # "2a"

2aNotSentBySafeAcceptor ==
    \A M \in msgs : M.type = "2a" => M.acc \notin SafeAcceptor

1bNotSentBySafeAcceptor ==
    \A M \in msgs : M.type = "1b" => M.acc \notin SafeAcceptor

NoDecision ==
    \A L \in Learner : \A BB \in Ballot : \A VV \in Value :
        VV \notin decision[L, BB]

UniqueDecision ==
    \A L1, L2 \in Learner: \A B1, B2 \in Ballot : \A V1, V2 \in Value :
        V1 \in decision[L1, B1] /\ V2 \in decision[L2, B2] =>
        V1 = V2

-----------------------------------------------------------------------------
(***************************************************************************)
(*                               Liveness                                  *)
(*                                                                         *)
(* For any learner L, ballot b and quorum Q of safe acceptors trusted by L *)
(* such that                                                               *)
(*                                                                         *)
(*  1. No phase 1a messages (a) have been or (b) ever will be sent for any *)
(*     ballot number greater than b.                                       *)
(*                                                                         *)
(*  2. The ballot b leader eventually sends a 1a message for ballot b.     *)
(*                                                                         *)
(*  3. Each acceptor in Q eventually receives the 1a message of ballot b   *)
(*     and responds to it by sending a 1b message.                         *)
(*                                                                         *)
(*  4. (a) Each acceptor in Q eventually receives a 1b message of ballot b *)
(*         from themself and every other acceptor of Q, and                *)
(*     (b) sends 2a containing the quorum of 1b messages to every learner  *)
(*         which live-trusts the quorum Q. In particular, the 2a messages  *)
(*         are sent to the learner L.                                      *)
(*                                                                         *)
(*  5. The learner L receives all 2a messages of ballot b addressed to it. *)
(*                                                                         *)
(*  6. Learner L eventually executes its decision action for ballot b if   *)
(*     it has a chance to do so.                                           *)
(*                                                                         *)
(* then some value is eventually chosen by the learner L.                  *)
(***************************************************************************)

THEOREM Liveness ==
    Spec =>
        \A L \in Learner : \A b \in Ballot, Q \in ByzQuorum :
            Q \subseteq SafeAcceptor /\
            [lr |-> L, q |-> Q] \in TrustLive =>
            (
              (
                \* (1a)
                /\ \A m \in msgs : m.type = "1a" => m.bal < b
                \* (1b)
                /\ \A c \in Ballot : c > b => [][~Send1a(c)]_vars
                \* (2)
                /\ WF_vars(Send1a(b))
                \* (3)
                /\ \A m \in Message :
                    B(m, b) =>
                    \A a \in Q : WF_vars(Process1a(a, m))
                \* (4a)
                /\ \A m \in Message :
                    B(m, b) =>
                    \A a \in Q : WF_vars(Process1b(a, m))
                \* (4b)
                /\ \A a \in Q : WF_vars(Process1bLearnerLoop(a))
                \* (5)
                /\ \A m \in Message :
                    B(m, b) => WF_vars(LearnerRecv(L, m))
                \* (6)
                /\ WF_vars(\E v \in Value : LearnerDecide(L, b, v))
              )
              ~>
              (\E BB \in Ballot : decision[L, BB] # {})
            )

CONSTANTS bb, LL, QQ

CSpec ==
    /\ Init
    /\ [][Next /\ \A c \in Ballot : c > bb => ~Send1a(c)]_vars
    /\ WF_vars(Send1a(bb))
    /\ \A m \in Message :
        B(m, bb) =>
        \A a \in QQ : WF_vars(Process1a(a, m))
    /\ \A m \in Message :
        B(m, bb) =>
        \A a \in QQ : WF_vars(Process1b(a, m))
    /\ \A a \in QQ : WF_vars(Process1bLearnerLoop(a))
    /\ \A m \in Message :
        B(m, bb) => WF_vars(LearnerRecv(LL, m))
    /\ WF_vars(\E v \in Value : LearnerDecide(LL, bb, v))

CLiveness ==
    (/\ QQ \subseteq SafeAcceptor
     /\ [lr |-> LL, q |-> QQ] \in TrustLive)
    =>
    ((\A m \in msgs : m.type = "1a" => m.bal < bb)
    ~>
    \E BB \in Ballot : decision[LL, BB] # {})

=============================================================================
\* Modification History
\* Last modified Mon Oct 17 16:29:25 CEST 2022 by karbyshev
\* Created Mon Jul 25 14:24:03 CEST 2022 by karbyshev
