+++
title = "Formal Methods"
date = 2026-02-18
lastmod = 2026-02-18
tags = ["formal-methods", "tla+", "alloy", "stateright", "learning", "industry", "verification"]
draft = false
description = "Formal software verification methods — history, tools (TLA+, Alloy, SPIN, Dafny, Lean 4), use cases at AWS, Intel, Airbus, seL4, and limitations. A guide to learning TLA+."
+++

## What are formal methods {#what-are-formal-methods}

Formal methods are mathematically rigorous techniques for specifying, designing, and verifying software and hardware systems. Instead of testing individual scenarios, formal methods can prove system properties for **all** possible states and execution paths.

The key idea: a system is described in a language with precise mathematical semantics, then automated tools (model checkers, theorem provers, SAT/SMT solvers) exhaustively verify given properties — or find a counterexample (error trace).


### Origins {#origins}

Formal methods grew out of the software crisis of the 1960s–70s, when it became clear that testing alone cannot prove the absence of bugs.

-   **Edsger Dijkstra** (1968) — "Go To Statement Considered Harmful" paper and the concept of structured programming. Later — the weakest preconditions formalism and the book "A Discipline of Programming" (1976), which laid the foundation for program verification.
-   **Tony Hoare** (1969) — Hoare logic: a formal system for reasoning about program correctness through pre- and postconditions `{P} C {Q}`. The foundation for all subsequent verification approaches.
-   **Amir Pnueli** (1977) — applied temporal logic to the verification of reactive systems. Awarded the Turing Prize (1996). Temporal logic became the basis of model checking.
-   **Edmund Clarke, Allen Emerson, Joseph Sifakis** (1981–82) — independently invented model checking — automatic verification of finite system models against temporal properties. Turing Award 2007.
-   **Leslie Lamport** — creator of TLA+ (Temporal Logic of Actions, 1999). A formalism for specifying concurrent and distributed systems. Lamport is also the author of Paxos, Bakery algorithm, and Lamport clocks. Turing Award 2013.
-   **Robin Milner** — process algebras (CCS, π-calculus) for modeling concurrent systems. Turing Award 1991.


### Why they matter {#why-they-matter}

Testing checks individual scenarios. Formal verification checks **all** possible scenarios.

Formal methods are especially valuable for:

-   Concurrent and distributed systems, where the number of states explodes combinatorially
-   Protocols that need to guarantee safety (nothing bad happens) and liveness (something good eventually happens)
-   Critical systems where the cost of a bug is money, reputation, or lives

Specific use cases, results, and lessons — in the section [Formal methods in industry](#formal-methods-in-industry-cases-and-results).


## Tool landscape {#tool-landscape}


### Classic tools {#classic-tools}


#### TLA+ {#tla-plus}

**Status: active development, new organizational structure**

-   The [TLA+ Foundation](https://foundation.tlapl.us/) has been created, funding development and publishing [monthly reports](https://foundation.tlapl.us/blog/2025-07-dev-update/)
-   The VS Code extension is actively developed and replaces the legacy Eclipse Toolbox — added Model Context Protocol support, TLC simulation statistics visualization
-   Ecosystem: 3 parsers (SANY, TLAPM, tree-sitter), 3 model checkers (TLC, Apalache, Spectacle), proof manager (TLAPM)
-   **Issues**: 25-year-old Java codebase, few tests, departure of original developers. A bytecode interpreter with potential 1000x speedup is under discussion
-   Joint [GenAI-Accelerated TLA+ Challenge](https://foundation.tlapl.us/challenge/index.html) with NVIDIA — exploring LLM usage for specification generation


Detailed overview: [The current state of TLA+ development (May 2025)](https://ahelwer.ca/post/2025-05-15-tla-dev-status/)


#### Alloy {#alloy}

**Status: stable, Alloy 6.2.0 (January 2025)**

-   [Alloy 6](https://alloytools.org/) — major revision: mutable state, temporal logic, new solvers, improved visualizer
-   New book: [Practical Alloy](https://haslab.github.io/formal-software-design/) — hands-on guide for Alloy 6+
-   Strengths: SAT-based analysis (fast), excellent handling of graphs and relations, transitive closure
-   Less expressive than TLA+, but simpler for structural modeling


#### SPIN / Promela {#spin-promela}

**Status: mature, maintained**

-   [SPIN](https://github.com/nimble-code/Spin) — classic model checker for concurrent protocols (LTL, Büchi automata)
-   Generates a problem-specific model checker in C — fast and memory-efficient
-   Stable community, but no notable new features in recent years


### New alternatives {#new-alternatives}


#### Quint {#quint}

**Status: active development, Informal Systems**

-   [Quint](https://github.com/informalsystems/quint) — modern specification language based on TLA (the logic), but with programmer-friendly syntax instead of LaTeX notation
-   Typing, modes (pure/action/temporal), REPL, CLI, instant feedback
-   Uses [Apalache](https://apalache-mc.org/) as backend for symbolic checking
-   **Note**: Apalache development slowed after being spun off from Informal Systems in late 2024


#### P (Microsoft Research) {#p--microsoft-research}

**Status: mature, used in production**

-   [P](https://github.com/p-org/P) — state-machine-based language for modeling asynchronous distributed systems
-   **Key difference from TLA+**: P programs compile to executable C code — a bridge between model and implementation
-   Used at AWS (S3 analysis) and Microsoft (Windows USB drivers — 300+ bugs found)


#### Stateright (Rust) {#stateright--rust}

**Status: niche but interesting**

-   [Stateright](https://github.com/stateright/stateright) — model checker embedded directly in Rust code
-   Verifies the implementation, not a separate model — no gap between specification and code
-   Includes a linearizability tester (similar to Jepsen, but exhaustive)
-   Faster than TLC, especially on large state spaces


#### Dafny {#dafny}

**Status: active development, Amazon**

-   [Dafny](https://github.com/dafny-lang/dafny) — verification-aware programming language
-   Amazon uses it for [Cedar](https://www.amazon.science/blog/how-we-built-cedar-with-automated-reasoning-and-differential-testing) (authorization policy language) — proving validator correctness
-   Active research on proof automation using LLMs (VeriCoding benchmarks)


#### Verus (Rust) {#verus--rust}

**Status: active academic development**

-   [Verus](https://www.cs.utexas.edu/~hleblanc/pdfs/verus.pdf) — formal verification of Rust code
-   Distinguishes ghost types (for specifications) and native Rust types
-   Active research: [AutoVerus](https://arxiv.org/pdf/2409.13082) — automatic generation of proof annotations via LLMs
-   2025–2026 benchmarks: 21k+ Rust programs, 9700+ verified


#### Lean 4 {#lean-4}

**Status: growing ecosystem**

-   Both a theorem prover and a programming language
-   Actively used in mathematics (Mathlib) and beginning to be applied to software verification
-   Included in multi-language benchmarks alongside Dafny and Verus


### Summary table {#summary-table}

| Tool                                                   | Approach                  | Model language | Status 2025-26                    |
|--------------------------------------------------------|---------------------------|----------------|-----------------------------------|
| [TLA+](https://foundation.tlapl.us/)                   | Model checking (explicit) | TLA+           | Active development, Foundation    |
| [Alloy](https://alloytools.org/)                       | SAT-based analysis        | Alloy          | Stable, v6.2                      |
| [SPIN](https://github.com/nimble-code/Spin)            | Model checking (LTL)      | Promela        | Mature, few updates               |
| [Quint](https://github.com/informalsystems/quint)      | Symbolic (Apalache)       | Quint (~TLA)   | Active, backend slowdown          |
| [P](https://github.com/p-org/P)                        | State machines → C code   | P              | Mature, production at AWS/MS      |
| [Stateright](https://github.com/stateright/stateright) | Embedded model checking   | Rust           | Niche                             |
| [Dafny](https://github.com/dafny-lang/dafny)           | Verification-aware prog.  | Dafny          | Active, Amazon                    |
| [Verus](https://github.com/verus-lang/verus)           | Rust verification         | Rust + ghost   | Academic growth                   |
| [Lean 4](https://github.com/leanprover/lean4)          | Theorem proving           | Lean           | Growing                           |


### Trends {#trends}

-   **Convergence of formal methods and AI** — LLM-based generation of specifications and proofs
-   **Blurring the line between model and implementation** — P, Stateright, Verus
-   **Lightweight formal methods** — Amazon Cedar/Dafny, practical approaches to production verification


## Formal methods in industry: cases and results {#formal-methods-in-industry-cases-and-results}

Formal methods are not just an academic discipline. Below are specific industry use cases with numbers, results, and lessons.


### Successes: where FM delivered measurable results {#successes-where-fm-delivered-measurable-results}


#### Amazon Web Services — TLA+ and P {#amazon-web-services-tla-plus-and-p}

Since 2011, AWS engineers have used TLA+ to verify critical distributed systems. According to Newcombe et al. (CACM, 2015), at the time of publication 7 teams had used TLA+ on 10 large real-world systems. In **all** cases, subtle bugs were found that had been missed by code review and testing.

Specific results from the paper ([Use of Formal Methods at Amazon Web Services](https://lamport.azurewebsites.net/tla/formal-methods-amazon.pdf)):

| Service  | Component                        | Lines of TLA+/PlusCal | Bugs found                       | Optimizations verified |
|----------|----------------------------------|-----------------------|----------------------------------|------------------------|
| S3       | Fault-tolerant network algorithm | 804 (PlusCal)         | 2 bugs                           | Yes                    |
| S3       | Background data redistribution   | 645 (PlusCal)         | 1 bug + bug in the initial fix   | Yes                    |
| DynamoDB | Replication and group membership | 939 (TLA+)            | 3 bugs (trace up to 35 steps)    | Yes                    |
| EBS      | Volume management                | ~100                  | Yes                              | Yes                    |
| Internal | Distributed lock manager         | —                     | Yes                              | —                      |

Especially notable is the DynamoDB bug: the shortest error trace contained 35 high-level steps. The bug passed through multiple design reviews, code reviews, and months of testing, but was found by the TLC model checker in seconds.

Engineers learned TLA+ in **2–3 weeks** and started getting useful results.

By 2024–2025, AWS expanded its practices: in addition to TLA+, they now use P (state-machine-based modeling), property-based testing, fuzzing, deterministic simulation, and runtime validation ([Systems Correctness Practices at AWS, CACM 2024](https://cacm.acm.org/practice/systems-correctness-practices-at-amazon-web-services/)). Formal specifications are used as **test oracles** — the source of correct answers for all other kinds of testing.


#### Intel — after the Pentium FDIV disaster {#intel-after-the-pentium-fdiv-disaster}

In 1994, a bug was discovered in the Pentium processor's floating-point division operation (FDIV bug). The cause: 5 out of 1066 entries in a lookup table were missing due to an error in the generation script ([Wikipedia: Pentium FDIV bug](https://en.wikipedia.org/wiki/Pentium_FDIV_bug)).

Recall cost: **$475 million** (over $1 billion in current prices). IBM halted shipments of Pentium computers on December 12, 1994, and a week later Intel announced a full recall ([Ken Shirriff, 2024](http://www.righto.com/2024/12/this-die-photo-of-pentium-shows.html)).

Consequences for Intel:

-   Formal verification became mandatory for arithmetic modules
-   During Pentium 4 development, symbolic trajectory evaluation and theorem proving were used, preventing similar bugs
-   The **Nehalem** architecture (2008) was the first where formal verification was the **primary** validation method
-   ~85 engineers were trained in formal methods

In the semiconductor industry overall, verification accounts for **50–70%** of chip development budget and timeline. The ratio of verification engineers to design engineers reaches 5:1 ([Semiconductor Engineering](https://semiengineering.com/knowledge_centers/eda-design/verification/formal-verification/)).


#### Airbus — Astrée and CompCert {#airbus-astrée-and-compcert}

**Astrée** — a static analyzer based on abstract interpretation. Proves the absence of runtime errors (division by zero, overflow, array out-of-bounds) in C programs.

Key result: in November 2003, Astrée **fully automatically** proved the absence of runtime errors in the fly-by-wire software of the **Airbus A340** ([Astrée project](https://www.astree.ens.fr/)):

-   **132,000 lines of C code** analyzed in 1 hour 20 minutes
-   On a PC with a 2.8 GHz processor, 300 MB of memory
-   **Zero false alarms**

Starting January 2004, Astrée was extended to analyze the A380 electric flight control software, completed before the A380's first flight (April 27, 2005).

**CompCert** — a formally verified C compiler. Airbus uses CompCert to compile onboard software. Result: **12%** improvement in worst-case execution time compared to unverified compilers ([AbsInt CompCert](https://www.absint.com/compcert/index.htm)).

In the famous study by Yang et al. (PLDI 2011), the Csmith tool found **325+ previously unknown bugs** in GCC, LLVM, and other compilers over 3 years. CompCert was the **only** compiler in whose verified parts Csmith could not find wrong-code generation errors.

DO-178C (2011) — the updated airborne software certification standard, which for the first time **officially** permits the use of formal verification in place of certain types of testing (supplement DO-333).


#### Paris Metro — Line 14 (Météor), B-method {#paris-metro-line-14-météor-b-method}

Line 14 of the Paris Metro is the first fully automated (driverless) metro line in a major national capital. Opened in 1998. The automatic train control system was developed by Matra Transport International for RATP using the **B-method** ([CLEARSY](https://www.clearsy.com/en/the-tools/extension-of-line-14-of-the-paris-metro-over-25-years-of-reliability-thanks-to-the-b-formal-method/)).

Results:

-   Safety-critical software developed using Atelier B (CLEARSY's B-method tool)
-   **27,800 lemmas** proved during development; ~*90% proved automatically*, the remaining 10% interactively
-   Code was generated from B specifications into Ada
-   **Zero bugs** found after proof completion — not during functional validation, integration testing, on-site trials, or throughout operation since 1998
-   "I have never seen anything like it: the software was practically perfect from the first time" — Claude Hennebert, RATP delegate
-   **25+ years** of fault-free operation; minimum train interval — 85 seconds
-   Daily ridership grew from 240,000 (2003) to 500,000+

The B-method has since been applied to many other metro lines and railway systems worldwide (CLEARSY).


#### seL4 — fully verified microkernel {#sel4-fully-verified-microkernel}

seL4 is the world's first **fully formally verified** general-purpose OS kernel ([seL4 Foundation](https://sel4.systems/)).

Metrics:

-   **8,700 lines of C** + 600 lines of assembly
-   **200,000 lines** of proofs in Isabelle/HOL
-   **20 person-years** of total effort (11 for seL4 proofs, 9 for frameworks and tools)
-   Estimated at ~10 person-years if repeated
-   Cost per line of code: ~*$400* (vs. ~$1,000 for traditional high-assurance systems)

What was proved:

-   Full functional correctness (from abstract specification to C implementation)
-   Absence of buffer overflow, null pointer dereference, use-after-free
-   Integrity and confidentiality guarantees

Performance: 227 cycles on the standard IPC benchmark (vs. 206 for unverified OKL4 2.1 — ~10% difference).


#### DARPA HACMS — unhackable military vehicles {#darpa-hacms-unhackable-military-vehicles}

The HACMS (High-Assurance Cyber Military Systems) program used seL4 in autonomous vehicles: trucks, ground robots, quadcopters, and the **Boeing Unmanned Little Bird** (unmanned helicopter) ([HACMS Program, PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC5597724/)).

Key experiment: a professional Red Team was given **full access** to the non-critical helicopter camera and even keys to crash the virtual machine — but **could not compromise** the flight mission. seL4 enforced partition isolation that the attackers could not breach.


#### Microsoft — SLAM, P, VCC {#microsoft-slam-p-vcc}

-   **SLAM / Static Driver Verifier (SDV)** — formal verification of Windows kernel-mode drivers. Used to test drivers shipped with Windows. In lab sessions, participants found at least one bug in their drivers ([SLAM paper, Microsoft Research](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr-2004-08.pdf))
-   **P** — used to implement and verify the USB 3.0 device driver stack in Windows 8.1 (2013). Result: 30% faster device enumeration, significantly fewer synchronization issues ([P on GitHub](https://github.com/p-org/P))
-   **VCC** — verification of Microsoft Hyper-V: **100,000 lines** of concurrent C code + 5,000 lines of assembly ([Verifying Hyper-V with VCC](https://www.researchgate.net/publication/221267843_Verifying_the_Microsoft_Hyper-V_Hypervisor_with_VCC))


### Anti-examples: what happens without formal methods {#anti-examples-what-happens-without-formal-methods}


#### Therac-25 (1985–1987) — patient deaths {#therac-25-1985-1987-patient-deaths}

The Therac-25 radiation therapy machine, due to a race condition in its control software, delivered **lethal radiation doses** to **6 patients** — **hundreds of times** higher than normal (up to 20,000 rads instead of 200). At least **3 people died**, and 3 others suffered severe injuries ([Wikipedia: Therac-25](https://en.wikipedia.org/wiki/Therac-25)).

What went wrong:

-   The software was written by a **single programmer** in PDP-11 assembly without formal specification or independent review
-   Hardware interlocks were replaced with software checks — without verification
-   Testing was minimal and did not cover timing-dependent scenarios
-   The race condition manifested only with a specific sequence of operator actions within an 8-second window

Lesson: it was after Therac-25 that safety-critical software engineering became a separate discipline, and the idea that "software can replace hardware interlocks" was rejected.


#### Ariane 5, Flight 501 (1996) — $370 million in 40 seconds {#ariane-5-flight-501-1996-370-million-in-40-seconds}

The Ariane 5 rocket exploded 40 seconds after launch due to an overflow when converting a 64-bit float to a 16-bit signed integer in the inertial navigation system. Total loss: **$370 million** (rocket + 4 scientific satellites). ESA had spent 10 years and **$7 billion** developing Ariane 5 ([Wikipedia: Ariane Flight V88](https://en.wikipedia.org/wiki/Ariane_flight_V88)).

The cause: the navigation module was reused from Ariane 4 without re-verifying input value ranges. Ariane 5's horizontal velocity was significantly higher than Ariane 4's, leading to the overflow.

Could formal analysis have helped? Yes — researchers demonstrated that a proof-based approach to systems engineering would have identified the range mismatch at design time, long before the first flight ([Ariane 5 Case Study](https://www.researchgate.net/publication/2637332_The_Ariane_5_Flight_501_Failure_-_A_Case_Study_in_System_Engineering_for_Computing_Systems)). Tools like Astrée would have detected the overflow automatically.


### The gap between model and implementation: Weave (Nim) {#the-gap-between-model-and-implementation-weave-nim}

The [Weave](https://github.com/mratsim/weave) project — a high-performance multithreaded runtime in Nim (author: Mamy Ratsimbazafy). An illustrative case: **the model is correct, the implementation is broken**.

What happened:

-   The backoff mechanism of the EventNotifier (a primitive: one consumer sleeps, multiple producers wake it) was specified in TLA+ and checked by the model checker against **~10 million states** — no deadlocks found ([Weave #18](https://github.com/mratsim/weave/issues/18))
-   But when running the N-Queens task (11 queens) on 2 threads — **consistent deadlock** ([Weave #43](https://github.com/mratsim/weave/issues/43))

Three layers of verification gap:

1.  **TLA+ verifies the design, not the code** — the model is correct, but errors were made when translating to Nim code (which compiles to C)
2.  **TLA+ does not model the hardware memory model** — acquire/release semantics of atomics, memory ordering, and write visibility across cores are invisible to the model checker. As the author wrote: "Model checking via TLA+ does not address implementation bugs due to misunderstanding the C11/C++11 memory model for atomics synchronization"
3.  **Bugs in dependencies** — even correct code breaks due to a **glibc bug**: lost wakeups in the condition variable implementation ([Weave #56](https://github.com/mratsim/weave/issues/56), [glibc #25847](https://sourceware.org/bugzilla/show_bug.cgi?id=25847)). The issue did not reproduce on macOS

Malte Skarupke independently confirmed the glibc bug via a TLA+/PlusCal model ([Using TLA+ to Understand a Glibc Bug](https://probablydance.com/2020/10/31/using-tla-in-the-real-world-to-understand-a-glibc-bug/), [TLA+ model](https://github.com/skarupke/glibc_cv_tla_plus)), and later found a [second bug](https://probablydance.com/2022/09/17/finding-the-second-bug-in-glibcs-condition-variable/).

Solution: Weave switched from glibc condition variables to **custom primitives based on Linux futex**, the backoff system was redesigned and re-verified (release [v0.2.0 "Overture"](https://github.com/mratsim/weave/releases)).

Lesson: formal verification of a model ≠ correctness of the implementation. Between a TLA+ specification and C/Nim code there remains a **verification gap** — low-level platform details (memory model, OS primitives, buggy dependencies). This led to [Nim RFC #222](https://github.com/nim-lang/RFCs/issues/222) — a proposal for tools to verify concurrent code directly in the language.


### Limitations and cost of formal methods {#limitations-and-cost-of-formal-methods}


#### Economics {#economics}

Formal methods are expensive upfront:

-   **seL4**: 20 person-years for 8,700 lines of C — but ~$400/line (vs. $1,000 for traditional high-assurance)
-   **Tokeneer** (Praxis/NSA): 10,000 lines of high-assurance code in 260 person-days — below the cost of traditional development ([Tokeneer](https://www.researchgate.net/publication/238770137_Tokeneer_Beyond_Formal_Program_Verification))
-   **Météor**: formal development took longer, but produced zero bugs and 25+ years without incidents — total cost of ownership is significantly lower

Formal methods are economically justified when:

-   Cost of a bug > cost of verification (aerospace, medicine, finance)
-   The system is long-lived — amortization of verification cost
-   Certification is required (DO-178C, Common Criteria)


#### Adoption barriers {#adoption-barriers}

According to industry surveys ([Cofer et al., 2013](https://www.researchgate.net/publication/269393704_Study_on_the_Barriers_to_the_Industrial_Adoption_of_Formal_Methods), [FM Expert Survey, 2020](https://www.fmeurope.org/documents/Garavel-terBeek-vandePol-20.pdf)):

1.  **Education** — 71.5% of experts consider insufficient engineer training the main barrier
2.  **Tools** — academic, poorly maintained, not integrated into CI/CD
3.  **Organizational environment** — staff turnover, contracts, deadline pressure
4.  **Scalability** — model checking suffers from state explosion on large systems
5.  **Skepticism** — perceived as "expensive, complex, and useless" despite proven results


#### Where FM don't work (or work poorly) {#where-fm-dont-work-or-work-poorly}

-   **Rapidly changing systems** — the cost of maintaining the specification may exceed the benefit
-   **UI/UX and visual systems** — formalization is difficult, properties are poorly defined
-   **Throwaway scripts and prototypes** — negative ROI
-   **ML/AI systems** — behavior is determined by data, not specification; verification is in the research stage
-   **Monolithic legacy systems** — too expensive to specify post-facto


#### Trend: decreasing cost {#trend-decreasing-cost}

The cost of formal methods is **decreasing**:

-   Lightweight approaches (TLA+ model checking, property-based testing) deliver results in days, not years
-   AWS: engineers become productive in TLA+ within 2–3 weeks
-   LLMs are beginning to generate specifications and proof annotations (AutoVerus, VeriCoding)
-   Integration into programming languages (Dafny, Verus) eliminates the model/code gap


## Learning TLA+ {#learning-tla-plus}


### Main resources {#main-resources}


#### Lamport's video course {#lamports-video-course}

[TLA+ Video Course](http://lamport.azurewebsites.net/video/videos.html) — the official course from the creator of TLA+. Covers the language, TLC model checker, and temporal logic basics. The best starting point.


#### Learn TLA+ {#learn-tla-plus}

[learntla.com](https://learntla.com/) — a practical tutorial by Hillel Wayne. Focuses on PlusCal and practical examples. Good as a supplement to the video course.


#### Specifying Systems {#specifying-systems}

[Specifying Systems](https://lamport.azurewebsites.net/tla/book.html) — Lamport's book, a complete TLA+ reference. Not for first reading — use as a reference after completing the course.


#### Practical TLA+ {#practical-tla-plus}

[Practical TLA+](https://link.springer.com/book/10.1007/978-1-4842-3829-5) — a book by Hillel Wayne. More accessible exposition with PlusCal examples.


### Visualization tools {#visualization-tools}


#### Spectacle {#spectacle}

[Spectacle](https://github.com/informalsystems/spectacle) — a browser-based model checker for TLA+/Quint. Visualizes the state graph directly in the browser, convenient for small models and learning.


#### TLA+ Graph Explorer {#tla-plus-graph-explorer}

Built into the TLA+ VS Code extension. Allows exploring the state graph after running TLC — state navigation, transition filtering.


#### TLA+ Animation {#tla-plus-animation}

[TLA+ Animation Module](https://github.com/will62794/tla-web) — web visualization of TLC traces. Allows creating animations to clearly demonstrate model behavior.


### Exercises by increasing complexity {#exercises-by-increasing-complexity}


#### 1. Counter {#1-counter}

**Goal**: learn basic TLA+/PlusCal syntax, variables, invariants.

-   One process, increments a variable from 0 to N
-   Invariant: `counter >= 0 /\ counter <= N`
-   Check liveness: `<>(counter = N)`


#### 2. Mutual Exclusion (Mutex) {#2-mutual-exclusion-mutex}

**Goal**: modeling concurrent processes, safety properties.

-   Two processes compete for a critical section
-   Implement Peterson's algorithm or a simple lock
-   Invariant: at most one process in the critical section
-   Find a safety violation with a naive implementation (without barriers)


#### 3. Producer-Consumer {#3-producer-consumer}

**Goal**: buffering, fairness, liveness.

-   Producer puts items into a bounded buffer, Consumer takes them
-   Safety: buffer does not overflow and does not go negative
-   Liveness: every produced item is eventually consumed (requires fairness)
-   Vary the number of producers/consumers


#### 4. Two-Phase Commit (2PC) {#4-two-phase-commit-2pc}

**Goal**: distributed protocols, failures, refinement.

-   Coordinator + N participants, transaction commit protocol
-   Safety: all participants reach the same decision (commit or abort)
-   Model participant failures
-   Verify that 2PC blocks on coordinator failure (a known limitation)
