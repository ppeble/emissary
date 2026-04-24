# End-to-End Tests

This directory contains black-box end-to-end tests that exercise a real
Emissary-ingress installation running in a local k3d cluster. Each test applies
Kubernetes manifests, runs requests, and asserts the response.

These tests are intentionally shell-based and schema-free: a fixture is any
subdirectory of `fixtures/` containing `manifests.yaml` and `verify.sh`. The
runner discovers them automatically — adding a new test means dropping in a new
directory, not editing any Go/Python test harness.

## Layout

```
test/e2e/
├── run.sh                      # fixture runner (iterates fixtures/, apply → verify → teardown)
└── fixtures/                   # one subdirectory per fixture
    └── <fixture-name>/
        ├── manifests.yaml      # kubectl apply'd into $NAMESPACE before verify
        └── verify.sh           # exit 0 = pass, non-zero = fail
```

The runner exports `GATEWAY_URL`, `NAMESPACE`, and `FIXTURE_DIR` into each
`verify.sh`. After every fixture it deletes what it applied, so fixtures don't
have to clean up after themselves.

## Running locally

Everything is driven through `make` targets defined in `build-aux/e2e.mk`.

### Prerequisites

- Docker running locally (k3d needs it).
- Python venv active so Makefile `python3` invocations resolve project deps:
  ```
  source .venv/bin/activate     # or: uv run make ...
  ```
- `k3d`, `kubectl`, and `helm` are fetched automatically into
  `tools/bin/` the first time they're needed.
- `grpcurl` on your `PATH` if you want to run the `grpc-basic` fixture locally
  (`brew install grpcurl` on macOS, or a release binary from
  [fullstorydev/grpcurl](https://github.com/fullstorydev/grpcurl/releases)).
  CI installs it automatically.

### Full cycle from scratch

```
make e2e/local
```

This runs, in order:
1. `e2e/cluster-up` — create a k3d cluster named `emissary-e2e` with ports
   80/443 (HTTP fixtures) and 6789 (TCPMapping fixtures) mapped to the host
   loadbalancer and Traefik disabled.
2. `make images` — build Emissary's container images via goreleaser snapshot.
3. `e2e/install` — import images into k3d, then `helm install` the CRDs chart
   and the ingress chart pinned to the locally-built image tag.
4. `e2e/run` — execute `run.sh` against the live cluster.

### Iterating

Once the cluster is up and Emissary is installed, you usually only need:

```
make e2e/run              # re-run fixtures against the existing deployment
```

If you changed code and want to redeploy without recreating the cluster:

```
make images && make VERSION=v4.0.0-local e2e/install
```

> **Why the `VERSION` override?** `make e2e/install` builds Helm charts whose
> metadata labels embed `VERSION`. A dirty working tree's default version
> (e.g. `4.0.2-0.20260422205059-<sha>-dirty.<ts>`) exceeds Kubernetes' 63-char
> label limit, and `helm install` rejects the CRDs with `metadata.labels:
> Invalid value: ... must be no more than 63 characters`. `make e2e/local`
> applies this override for you automatically; `make e2e/install` on its own
> does not, so pass it explicitly (or set `E2E_LOCAL_VERSION` in the
> environment). Use any short string — `v4.0.0-local` is just the default.

> **Adding a new edge port?** k3d's published ports are fixed at cluster
> creation time. If you add a port to `e2e/cluster-up` (or want the existing
> 6789 on a cluster you created before it was added), you have to
> `make e2e/cluster-down && make e2e/cluster-up` to pick it up — `helm
> upgrade` alone won't get traffic in.

### Teardown

```
make e2e/cluster-down
```

### Overridable variables

All have sensible defaults; override on the command line as needed:

| Variable             | Default                | Purpose                                  |
|----------------------|------------------------|------------------------------------------|
| `E2E_CLUSTER`        | `emissary-e2e`         | k3d cluster name                         |
| `E2E_NAMESPACE`      | `emissary`             | namespace for ingress + fixtures         |
| `E2E_CRD_NAMESPACE`  | `emissary-system`      | namespace for the CRDs chart             |
| `E2E_GATEWAY_URL`    | `http://localhost`     | URL `verify.sh` probes                   |
| `E2E_LOCAL_VERSION`  | `v4.0.0-local`         | short chart VERSION (dirty trees produce strings longer than k8s' 63-char label limit) |
| `VERIFY_TIMEOUT`     | `120` (run.sh env)     | per-fixture verify timeout in seconds    |

## Adding a new fixture

1. Create `test/e2e/fixtures/<name>/`.
2. Put the resources you want in `manifests.yaml` (Deployment, Service,
   Mapping, whatever the scenario needs).
3. Write `verify.sh` so that it exits 0 on success. It can assume
   `GATEWAY_URL`, `NAMESPACE`, and `FIXTURE_DIR` are set. Retry loops are your
   responsibility — pods take a moment to become ready.
4. Run `make e2e/run` and confirm it passes.

No registration step is required — `run.sh` picks up every subdirectory of
`fixtures/` that has both required files.

## How CI runs this

`.github/workflows/test-images.yaml` mirrors the local flow: it spins up k3d,
imports the images built by `build-images`, `helm install`s the charts
produced by `build-charts` (pinned to that same image tag), and then runs
`test/e2e/run.sh`. On failure it dumps pod state and the last 500 lines of
Emissary logs.

The key difference from local: CI consumes pre-built image and chart artifacts
from upstream jobs instead of running `make images` / `make charts` itself.
