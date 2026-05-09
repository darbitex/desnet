# Setup & Building

DeSNet is built using the Move programming language on the Aptos blockchain.

## Source Layout

- `sources/`: All Move modules implementing the protocol logic.
- `tests/`: Integration and unit tests.
- `docs/`: Design documents and audit reports.

## Prerequisites

- [Aptos CLI](https://aptos.dev/tools/aptos-cli/install-cli/index)
- Move compiler (included with Aptos CLI)

## Compiling

To compile the DeSNet package, use the following command. You will need to provide the named addresses for the deployment.

```bash
aptos move compile --named-addresses \
  desnet=<deploy_addr>,origin=<origin_addr>,desnet_claimer=<claimer_addr>
```

## Testing

DeSNet maintains a comprehensive test suite. To run the tests:

```bash
aptos move test
```

## Deployment

Mainnet deployment is managed via the `governance` module using a chunked upgrade process to handle the package size.
