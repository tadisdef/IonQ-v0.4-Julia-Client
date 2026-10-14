# IonQ v0.4 Julia Client

This project provides a clean Julia client for the IonQ Quantum Cloud REST API v0.4.

It is built around a small circuit abstraction, API wrapper, polling helper, and result-decoding utilities so you can submit jobs without manually crafting every JSON payload by hand.

This was built by Andrew Edwards https://github.com/tadisdef

Be sure to get your API key for the free simulator at https://cloud.ionq.com/

## Features

- Authenticated API calls using `apiKey <your-key>`
- Circuit builder for IonQ gate-list jobs
- Submission for `ionq.circuit.v1` jobs
- Job polling and final-state handling
- Probability decoding and bitstring formatting
- Offline self-tests
- Example GHZ demo

## Requirements

Use Julia 1.9+ and install the following packages through the Julia package manage:

```julia
using Pkg
Pkg.add(["HTTP", "JSON3"])
```

## Configuration

Set your IonQ API key in the environment (remember to register for this on the IONQ cloud site):

PowerShell:

```powershell
$env:IONQ_API_KEY = "your-api-key"
```

bash/zsh:

```bash
export IONQ_API_KEY="your-api-key"
```

Optional:

```powershell
$env:IONQ_BASE_URL = "https://api.ionq.co/v0.4"
```

## Basic usage

```julia
include("ionq_client_v0_4.jl")
using .IonQ

c = IonQ.Client(api_key = ENV["IONQ_API_KEY"])
q = IonQ.Circuit(2)
IonQ.h!(q, 1)
IonQ.cnot!(q, 1, 2)

probs = IonQ.execute(c, q; shots = 1024, backend = "simulator")
println(IonQ.bitstring_probs(probs, 2))
```

## Build a circuit manually (this example is a 3 qubit GHZ circuit)

```julia
q = IonQ.Circuit(3)
IonQ.h!(q, 1)
IonQ.cnot!(q, 1, 2)
IonQ.cnot!(q, 1, 3)

payload = IonQ.job_payload(q; shots = 512, backend = "simulator")
println(payload)
```

## Run the self-test

```bash
julia ionq_client_v0_4.jl --selftest
```

This checks internal assumptions without making network requests.

## Run the demo

```bash
julia ionq_client_v0_4.jl
```

The demo submits a 3-qubit GHZ circuit to IonQ's simulator and prints measured probabilities.

## Notes on IonQ v0.4 best practices

- Use `Authorization: apiKey <key>` exactly.
- Keep `base_url` at `https://api.ionq.co/v0.4` unless you are intentionally using a different environment.
- Convert qubit indices carefully: IonQ expects zero-based indices on the wire, while the Julia client exposes 1-based qubit indexing for convenience.
- Poll until the job reaches a terminal status: `completed`, `failed`, or `canceled`.
- Use `results/probabilities` for probability distributions when available.
- Validate input circuits before sending them to the API.
- Keep API keys out of source files; prefer environment variables (this prevents accidental sharing).

## File layout

- `ionq_client_v0_4.jl` — the client implementation
- `IONQ_CLIENT_README.md` — usage instructions

## Troubleshooting

### Missing API key

If you see an error about a missing API key, set `IONQ_API_KEY` before running the script.

### Polling timeouts

Increase the timeout if your job is queued longer than expected:

```julia
IonQ.wait_for_job(c, job_id; timeout = 900, poll = 2.0)
```

### Invalid backend

Use a valid backend for your account, such as:

```julia
"simulator"
```

or another backend available from the IonQ account.

## License

This example is provided for learning and experimentation. Adapt it to your project as needed and have fun!
