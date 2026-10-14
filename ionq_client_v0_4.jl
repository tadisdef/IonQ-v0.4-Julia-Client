#!/usr/bin/env julia
# ionq_client_v0_4.jl
#
# A clean, reusable Julia client for the IonQ Quantum Cloud REST API (v0.4).
#
# Built by Andrew Edwards - https://github.com/tadisdef
#
# Setup:
#   1) Install dependencies:
#        julia -e 'using Pkg; Pkg.add(["HTTP", "JSON3"])'
#   2) Set your API key:
#        PowerShell: $env:IONQ_API_KEY = "your-api-key"
#        Bash/zsh:   export IONQ_API_KEY="your-api-key"
#   3) Run:
#        julia ionq_client_v0_4.jl --selftest
#        julia ionq_client_v0_4.jl
#
# Notes:
#   - IonQ requires a bearer-style API key in the Authorization header:
#         "Authorization" => "apiKey <key>"
#   - You can sign up for an API key and run the simulator for free
#   - IonQ job payloads use zero-based qubit indexing in the wire format.
#   - The library exposes a small circuit builder so you can write circuits without
#     manually constructing raw JSON dictionaries.
#   - The API base URL is usually: https://api.ionq.co/v0.4
#
# Example usage from Julia:
#   include("ionq_client_v0_4.jl")
#   using .IonQ
#
#   c = IonQ.Client(api_key = ENV["IONQ_API_KEY"])
#   q = IonQ.Circuit(2)
#   IonQ.h!(q, 1)
#   IonQ.cnot!(q, 1, 2)
#   probs = IonQ.execute(c, q; shots = 1024, backend = "simulator")
#   println(IonQ.bitstring_probs(probs, 2))
#
# This file includes a few comments and helper functions so it is easier to
# learn from and adapt to other IonQ job types.

module IonQ

using HTTP
using JSON3

export Client, Circuit, IonQError,
       h!, x!, y!, z!, s!, si!, t!, ti!, v!, vi!,
       rx!, ry!, rz!, cnot!, swap!,
       job_payload, submit, job, jobs, status, cancel, cost, estimate, backends,
       wait_for_job, probabilities, execute, bitstring_probs, counts,
       selftest, demo

const TERMINAL_STATUSES = ("completed", "failed", "canceled")

# ---------------------------------------------------------------------------
# Errors and client
# ---------------------------------------------------------------------------

"""Raised when IonQ returns a non-2xx HTTP response."""
struct IonQError <: Exception
    status::Int
    body::String
end

function Base.showerror(io::IO, e::IonQError)
    print(io, "IonQ API error (HTTP ", e.status, "): ", e.body)
end

"""
    Client(; api_key = ENV["IONQ_API_KEY"], base_url = "https://api.ionq.co/v0.4", readtimeout = 30)

Holds the authentication key and HTTP connection settings.
"""
struct Client
    api_key::String
    base_url::String
    readtimeout::Int
end

function Client(; api_key::AbstractString = get(ENV, "IONQ_API_KEY", ""),
                  base_url::AbstractString = "https://api.ionq.co/v0.4",
                  readtimeout::Integer = 30)
    isempty(api_key) && throw(ArgumentError(
        "No API key: pass api_key=... or set the IONQ_API_KEY environment variable"
    ))
    return Client(String(api_key), String(rstrip(String(base_url), '/')), Int(readtimeout))
end

Base.show(io::IO, c::Client) =
    print(io, "IonQ.Client(base_url=\"", c.base_url, "\", api_key=<redacted>)")

function _request(c::Client, method::AbstractString, path::AbstractString;
                  body = nothing, query = nothing)
    headers = Pair{String,String}["Authorization" => "apiKey " * c.api_key,
                                  "Accept" => "application/json"]
    payload = ""
    if body !== nothing
        push!(headers, "Content-Type" => "application/json")
        payload = JSON3.write(body)
    end

    kw = query === nothing ? NamedTuple() : (query = query,)

    resp = HTTP.request(method, c.base_url * path, headers, payload;
                        status_exception = false,
                        readtimeout = c.readtimeout,
                        kw...)

    text = String(resp.body)
    (200 <= resp.status < 300) || throw(IonQError(resp.status, text))
    return isempty(text) ? nothing : JSON3.read(text)
end


# ---------------------------------------------------------------------------
# Circuit builder (IonQ "qis" gateset)
# ---------------------------------------------------------------------------


"""
    Circuit(n)

A circuit on `n` qubits. Gates are appended with the `!` methods.
"""
mutable struct Circuit
    nqubits::Int
    ops::Vector{Dict{String,Any}}
    function Circuit(n::Integer)
        n >= 1 || throw(ArgumentError("a circuit needs at least one qubit"))
        return new(Int(n), Dict{String,Any}[])
    end
end

Base.length(c::Circuit) = length(c.ops)
Base.show(io::IO, c::Circuit) =
    print(io, "Circuit(", c.nqubits, " qubits, ", length(c.ops), " gates)")

# Convert a 1-based qubit index to IonQ's 0-based index, with range checking.
function _q(c::Circuit, q::Integer)
    1 <= q <= c.nqubits ||
        throw(ArgumentError("qubit $q is out of range 1:$(c.nqubits)"))
    return Int(q) - 1
end

# Single-qubit gates: h!, x!, y!, z!, s!, si!, t!, ti!, v!, vi!
for (fname, gate) in ((:h!, "h"), (:x!, "x"), (:y!, "y"), (:z!, "z"),
                      (:s!, "s"), (:si!, "si"), (:t!, "t"), (:ti!, "ti"),
                      (:v!, "v"), (:vi!, "vi"))
    @eval function $fname(c::Circuit, q::Integer)
        push!(c.ops, Dict{String,Any}("gate" => $gate, "target" => _q(c, q)))
        return c
    end
end

# Rotations (angle in radians)
for (fname, gate) in ((:rx!, "rx"), (:ry!, "ry"), (:rz!, "rz"))
    @eval function $fname(c::Circuit, q::Integer, θ::Real)
        isfinite(θ) || throw(ArgumentError("rotation angle must be finite"))
        push!(c.ops, Dict{String,Any}("gate" => $gate,
                                      "target" => _q(c, q),
                                      "rotation" => Float64(θ)))
        return c
    end
end

function cnot!(c::Circuit, control::Integer, target::Integer)
    control == target && throw(ArgumentError("control and target must differ"))
    push!(c.ops, Dict{String,Any}("gate" => "cnot",
                                  "control" => _q(c, control),
                                  "target" => _q(c, target)))
    return c
end

function swap!(c::Circuit, a::Integer, b::Integer)
    a == b && throw(ArgumentError("swap needs two different qubits"))
    push!(c.ops, Dict{String,Any}("gate" => "swap", "targets" => [_q(c, a), _q(c, b)]))
    return c
end


# ---------------------------------------------------------------------------
# API calls
# ---------------------------------------------------------------------------


"""
    job_payload(circuit; shots = 1024, backend = "simulator", name = "julia-job", extra = Dict())

Build the JSON object for `POST /jobs`.
"""
# You can see here we are setting the default shots to 1024 for the simulator, as mentioned in the previous comments
function job_payload(circuit::Circuit;
                     shots::Integer = 1024,
                     backend::AbstractString = "simulator",
                     name::AbstractString = "julia-job",
                     extra::AbstractDict = Dict{String,Any}())
    isempty(circuit.ops) && throw(ArgumentError("circuit has no gates"))
    shots >= 1 || throw(ArgumentError("shots must be positive"))

    payload = Dict{String,Any}(
        "type" => "ionq.circuit.v1",
        "name" => String(name),
        "shots" => Int(shots),
        "backend" => String(backend),
        "input" => Dict{String,Any}(
            "qubits" => circuit.nqubits,
            "gateset" => "qis",
            "circuit" => circuit.ops,
        ),
    )

    for (k, v) in extra
        payload[string(k)] = v
    end
    return payload
end

"List available backends (`GET /backends`)."
backends(c::Client) = _request(c, "GET", "/backends")

"Submit a circuit and return the new job ID."
function submit(c::Client, circuit::Circuit; kwargs...)
    resp = _request(c, "POST", "/jobs"; body = job_payload(circuit; kwargs...))
    return String(resp.id)
end

"Fetch the full job record (`GET /jobs/{id}`)."
job(c::Client, id::AbstractString) = _request(c, "GET", "/jobs/" * String(id))

"Return the current job status as a string."
status(c::Client, id::AbstractString) = String(job(c, id).status)

"List jobs (`GET /jobs`). Keyword arguments become query parameters."
function jobs(c::Client; query...)
    q = isempty(query) ? nothing : Dict(string(k) => string(v) for (k, v) in query)
    return _request(c, "GET", "/jobs"; query = q)
end

"Cancel a queued or running job (`PUT /jobs/{id}/status/cancel`)."
cancel(c::Client, id::AbstractString) =
    _request(c, "PUT", "/jobs/" * String(id) * "/status/cancel")

"Billing details for a job (`GET /jobs/{id}/cost`)."
cost(c::Client, id::AbstractString) = _request(c, "GET", "/jobs/" * String(id) * "/cost")

"Estimate cost or runtime (`GET /jobs/estimate`)."
function estimate(c::Client; params...)
    q = isempty(params) ? nothing : Dict(string(k) => string(v) for (k, v) in params)
    return _request(c, "GET", "/jobs/estimate"; query = q)
end

"""
    wait_for_job(c, id; timeout = 600, poll = 1.0, max_poll = 15.0)

Poll until the job reaches a final state and return the full job record.
"""
function wait_for_job(c::Client, id::AbstractString;
                      timeout::Real = 600, poll::Real = 1.0, max_poll::Real = 15.0)
    t0 = time()
    delay = float(poll)
    while true
        j = job(c, id)
        s = String(j.status)
        s in TERMINAL_STATUSES && return j
        time() - t0 > timeout &&
            error("Timed out after $(timeout)s waiting for job $id (last status: $s)")
        sleep(delay)
        delay = min(delay * 1.5, max_poll)
    end
end

"""
    probabilities(c, id) -> Dict{Int,Float64}

Fetch the probabilities endpoint and convert keys to integer probabilities.
"""
function probabilities(c::Client, id::AbstractString)
    raw = _request(c, "GET", "/jobs/" * String(id) * "/results/probabilities")
    return Dict{Int,Float64}(parse(Int, String(k)) => Float64(v) for (k, v) in pairs(raw))
end

"""
    execute(c, circuit; timeout = 600, kwargs...) -> Dict{Int,Float64}

Submit, wait, and return the observed probabilities for a completed job.
"""
function execute(c::Client, circuit::Circuit; timeout::Real = 600, kwargs...)
    id = submit(c, circuit; kwargs...)
    @info "Submitted IonQ job" id
    j = wait_for_job(c, id; timeout = timeout)
    s = String(j.status)
    if s != "completed"
        detail = get(j, :failure, nothing)
        error("Job $id ended with status '$s'" *
              (detail === nothing ? "" : ": $(detail)"))
    end
    return probabilities(c, id)
end


# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------


"""
    bitstring_probs(probs, n; qubit1_first = true) -> Dict{String,Float64}

Convert little-endian integer keys into readable bitstring labels.
"""
function bitstring_probs(probs::AbstractDict{<:Integer,<:Real}, n::Integer;
                         qubit1_first::Bool = true)
    out = Dict{String,Float64}()
    for (key, p) in probs
        bits = [(key >> (i - 1)) & 1 for i in 1:n]
        qubit1_first || reverse!(bits)
        out[join(bits)] = p
    end
    return out
end

"Approximate shot counts from probabilities."
counts(probs::AbstractDict{<:Integer,<:Real}, shots::Integer) =
    Dict{Int,Int}(k => round(Int, p * shots) for (k, p) in probs)


# ---------------------------------------------------------------------------
# Offline self-test and demo
# ---------------------------------------------------------------------------


function _check(cond::Bool, msg::AbstractString)
    cond || error("selftest failed: " * msg)
    println("  ok  ", msg)
end

_throws(T::Type, f::Function) = try
    f()
    false
catch e
    e isa T
end

# this self test is running the ghz cirtcuit with 1024 shots on the simulator and checking the results

function selftest()
    println("Running offline self-tests...")

    ghz = Circuit(3)
    h!(ghz, 1); cnot!(ghz, 1, 2); cnot!(ghz, 1, 3)
    p = job_payload(ghz; shots = 1024, backend = "simulator", name = "Hello many worlds")
    _check(p["type"] == "ionq.circuit.v1" && p["backend"] == "simulator" && p["shots"] == 1024,
           "payload header fields")
    _check(p["input"]["qubits"] == 3 && p["input"]["gateset"] == "qis",
           "input header fields")
    _check(ghz.ops == [Dict("gate" => "h", "target" => 0),
                       Dict("gate" => "cnot", "control" => 0, "target" => 1),
                       Dict("gate" => "cnot", "control" => 0, "target" => 2)],
           "GHZ circuit matches IonQ's documented JSON")

    parsed = JSON3.read(JSON3.write(p))
    _check(parsed.input.circuit[2].control == 0 && parsed.input.circuit[2].target == 1,
           "JSON round-trip")

    r = Circuit(1); rx!(r, 1, pi / 2)
    _check(r.ops[1]["rotation"] ≈ pi / 2, "rotation gate stores radians")

    w = Circuit(2); swap!(w, 1, 2)
    _check(w.ops[1]["targets"] == [0, 1], "swap uses 0-based targets")

    _check(_throws(ArgumentError, () -> h!(Circuit(2), 3)), "out-of-range qubit rejected")
    _check(_throws(ArgumentError, () -> h!(Circuit(2), 0)), "qubit 0 rejected")
    _check(_throws(ArgumentError, () -> cnot!(Circuit(2), 1, 1)), "control == target rejected")
    _check(_throws(ArgumentError, () -> rx!(Circuit(1), 1, NaN)), "non-finite angle rejected")
    _check(_throws(ArgumentError, () -> job_payload(Circuit(2))), "empty circuit rejected")
    _check(_throws(ArgumentError, () -> job_payload(ghz; shots = 0)), "zero shots rejected")

    probs = Dict(3 => 0.5, 4 => 0.5)
    _check(bitstring_probs(probs, 3) == Dict("110" => 0.5, "001" => 0.5),
           "little-endian keys -> qubit-1-first labels")
    _check(bitstring_probs(probs, 3; qubit1_first = false) == Dict("011" => 0.5, "100" => 0.5),
           "little-endian keys -> qubit-1-last labels")
    _check(counts(Dict(0 => 0.5, 7 => 0.5), 1000) == Dict(0 => 500, 7 => 500),
           "counts from probabilities")

    _check(_throws(ArgumentError, () -> Client(api_key = "")), "missing API key rejected")
    c = Client(api_key = "secret123")
    _check(!occursin("secret123", sprint(show, c)), "API key is redacted when printed")

    println("All self-tests passed.")
end

# this demo is running the ghz cirtcuit with 1024 shots on the simulator and printing the results

function demo()
    if !haskey(ENV, "IONQ_API_KEY")
        error("Set IONQ_API_KEY before running the demo. Example: $env:IONQ_API_KEY = \"your-key\"")
    end

    c = Client()
    ghz = Circuit(3)
    h!(ghz, 1); cnot!(ghz, 1, 2); cnot!(ghz, 1, 3)
    println("Submitting a 3-qubit GHZ circuit to IonQ's simulator...")
    probs = execute(c, ghz; shots = 1024, backend = "simulator", name = "Julia GHZ demo")
    println("Outcome probabilities (qubit 1 is the leftmost bit):")
    for (bits, p) in sort!(collect(bitstring_probs(probs, ghz.nqubits)); by = first)
        println("  ", bits, "  ", round(p; digits = 4))
    end
end

end # module IonQ

if abspath(PROGRAM_FILE) == @__FILE__
    if "--selftest" in ARGS
        IonQ.selftest()
    else
        IonQ.demo()
    end
end
