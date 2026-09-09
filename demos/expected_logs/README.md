# Expected logs

One directory per demo: `driver.log` as that demo printed it on a working system, and a
`provenance.txt` naming the backline, Catalyst and PennyLane commits it ran against.

Read them for shape, not text. A difference is not a failure: timings, hosts and paths vary with
the machine, and where a demo simulates rather than using `null.qubit`, shot outcomes are random
too. A demo is right when the same nodes come up and report the same things, in roughly the same
order, and it reaches its sample output without an exception.

Reproduce one, replacing its directory:

```bash
./scripts/run-demo.sh demo_1_local_cpu_to_local_cpu_memcpy.py
```
