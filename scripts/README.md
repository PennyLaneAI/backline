# Scripts

Helpers for running the material in this repository.

| | |
|---|---|
| [sweep-bench.sh](sweep-bench.sh) | run [`../benchmarks/bench.py`](../benchmarks/bench.py) once per cell and collect the CSVs into one directory |
| [run-demo.sh](run-demo.sh) | run one of [`../demos`](../demos) and collect its output as that demo's reference log |

To install from nothing, follow [`../INSTALL.md`](../INSTALL.md).

```bash
./sweep-bench.sh -h          # options
./sweep-bench.sh -n          # print what would run, run nothing
./sweep-bench.sh -o results  # write the CSVs to ./results/
```

Anything after `--` is passed to every `bench.py` run:

```bash
./sweep-bench.sh -- --iters 100000
```

`run-demo.sh` writes into [`../demos/expected_logs/<demo>/`](../demos/expected_logs), replacing what
is there, so the logs committed as references are refreshed deliberately:

```bash
./run-demo.sh demo_1_local_cpu_to_local_cpu_memcpy.py
```
