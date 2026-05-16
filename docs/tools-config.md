# Tools Config

Manage Jenkins → Tools → Go section → Add Go:

- Name: `GO_1_23`
- Install automatically: **unchecked** (already installed by user data)
- GOROOT: `/usr/local/go`

Save.

The Jenkinsfile references this name in its `tools { go 'GO_1_23' }` block.
