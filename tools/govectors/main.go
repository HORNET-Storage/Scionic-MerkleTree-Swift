// Command govectors emits golden CBOR wire vectors from the DEPLOYED Go
// Scionic Merkle Tree implementation so the Swift port can prove, byte for
// byte, that it reads exactly what desktop relays emit.
//
// Library: github.com/HORNET-Storage/Scionic-Merkle-Tree/v2 v2.2.6 — the
// version pinned by HORNETS-Nostr-Relay and hdk-nostr-go (the relay serving
// path mobile downloads from). The runtime-resolved version is printed in the
// output as proof.
//
// Regenerate (from tools/govectors; also rewrites the Swift fixture file):
//   go run . -swift ../../tests/tests/crosscompat/CrossCompatWireVectors.swift > vectors.json
//
// Determinism: the tree lives in a fixed-name "golden-repo" directory with
// fixed file bytes and CreateDag(path, false) (no root timestamp), so the DAG
// root and every leaf CID are identical on every run and on every machine.
// CBOR map key ORDER inside a packet is not guaranteed across runs (Go map
// iteration order); that is irrelevant to the Swift tests, which decode the
// recorded bytes rather than re-encoding them.
//
// Vector (i)  skeletonPacketsHex: content-free batched leaf sequence — the
//             wire shape of the relay's handleStreamingDownload (skeleton).
// Vector (ii) selectedLeafPacketsHex: content-carrying partial DAG for the
//             readme.md leaf — the wire shape of handlePartialDownload
//             (selected-file download with pruned links).
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"

	scionic "github.com/HORNET-Storage/Scionic-Merkle-Tree/v2/dag"
)

type vectors struct {
	LibraryVersion         string   `json:"libraryVersion"`
	Root                   string   `json:"root"`
	ReadmeLeafHash         string   `json:"readmeLeafHash"`
	ReadmeContentHex       string   `json:"readmeContentHex"`
	SkeletonPacketsHex     []string `json:"skeletonPacketsHex"`
	SelectedLeafPacketsHex []string `json:"selectedLeafPacketsHex"`
}

func main() {
	swiftOut := flag.String("swift", "", "path to also write the generated Swift fixture file (CrossCompatWireVectors.swift)")
	flag.Parse()

	base, err := os.MkdirTemp("", "govectors")
	must(err)
	defer os.RemoveAll(base)

	// Fixed names + fixed bytes => deterministic CIDs. The DAG root leaf takes
	// the directory's base name, so it must NOT be the random temp dir itself.
	repo := filepath.Join(base, "golden-repo")
	readme := []byte("hello golden repos")
	guide := []byte("swift parity guide")
	must(os.MkdirAll(filepath.Join(repo, "docs"), 0o755))
	must(os.WriteFile(filepath.Join(repo, "readme.md"), readme, 0o644))
	must(os.WriteFile(filepath.Join(repo, "docs", "guide.md"), guide, 0o644))

	built, err := scionic.CreateDag(repo, false)
	must(err)
	must(built.Verify())

	readmeLeafHash := ""
	for hash, leaf := range built.Leafs {
		if leaf.ItemName == "readme.md" {
			readmeLeafHash = hash
		}
	}
	if readmeLeafHash == "" {
		panic("readme.md leaf not found in built DAG")
	}

	// Vector (ii): selected-leaf partial with content (handlePartialDownload).
	partial, err := built.GetPartial([]string{readmeLeafHash}, true)
	must(err)
	must(partial.Verify())
	partialReadme := partial.Leafs[readmeLeafHash]
	if partialReadme == nil || !bytes.Equal(partialReadme.Content, readme) {
		panic("partial DAG did not retain readme.md content; vectors would not represent a file download")
	}
	selected := encodePackets(partial)

	// Vector (i): content-free skeleton batches (handleStreamingDownload).
	built.RemoveAllContent()
	skeleton := encodePackets(built)

	out := vectors{
		LibraryVersion:         scionicVersion(),
		Root:                   built.Root,
		ReadmeLeafHash:         readmeLeafHash,
		ReadmeContentHex:       hex.EncodeToString(readme),
		SkeletonPacketsHex:     skeleton,
		SelectedLeafPacketsHex: selected,
	}
	encoded, err := json.MarshalIndent(out, "", "  ")
	must(err)
	fmt.Println(string(encoded))

	if *swiftOut != "" {
		must(writeSwiftFixtures(out, *swiftOut))
	}
}

func encodePackets(d *scionic.Dag) []string {
	batches := d.GetBatchedLeafSequence()
	if len(batches) == 0 {
		panic("GetBatchedLeafSequence returned no batches")
	}
	result := make([]string, 0, len(batches))
	for _, batch := range batches {
		raw, err := batch.ToCBOR()
		must(err)
		result = append(result, hex.EncodeToString(raw))
	}
	return result
}

func scionicVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, dep := range info.Deps {
		if dep.Path == "github.com/HORNET-Storage/Scionic-Merkle-Tree/v2" {
			return dep.Version
		}
	}
	return "unknown"
}

// writeSwiftFixtures renders the vectors as a generated Swift enum so the
// parity tests never depend on hand-transcribed hex.
func writeSwiftFixtures(v vectors, path string) error {
	var b strings.Builder
	b.WriteString("// GENERATED FILE — DO NOT EDIT BY HAND.\n")
	b.WriteString("// Golden CBOR wire vectors from the deployed Go Scionic Merkle Tree implementation\n")
	fmt.Fprintf(&b, "// (github.com/HORNET-Storage/Scionic-Merkle-Tree/v2 %s). Regenerate:\n", v.LibraryVersion)
	b.WriteString("//   cd tools/govectors && go run . -swift ../../tests/tests/crosscompat/CrossCompatWireVectors.swift > vectors.json\n")
	b.WriteString("// See CrossCompatWireTests.swift for the assertions these vectors pin.\n")
	b.WriteString("\n")
	b.WriteString("enum CrossCompatWireVectors {\n")
	fmt.Fprintf(&b, "    static let libraryVersion = %q\n", v.LibraryVersion)
	fmt.Fprintf(&b, "    static let root = %q\n", v.Root)
	fmt.Fprintf(&b, "    static let readmeLeafHash = %q\n", v.ReadmeLeafHash)
	fmt.Fprintf(&b, "    static let readmeContentHex = %q\n", v.ReadmeContentHex)
	b.WriteString("    static let skeletonPacketsHex: [String] = [\n")
	for _, hexPacket := range v.SkeletonPacketsHex {
		fmt.Fprintf(&b, "        %q,\n", hexPacket)
	}
	b.WriteString("    ]\n")
	b.WriteString("    static let selectedLeafPacketsHex: [String] = [\n")
	for _, hexPacket := range v.SelectedLeafPacketsHex {
		fmt.Fprintf(&b, "        %q,\n", hexPacket)
	}
	b.WriteString("    ]\n")
	b.WriteString("}\n")
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
