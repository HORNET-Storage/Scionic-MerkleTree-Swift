// Command gofixtureroots prints the DAG root (and structural stats) that the
// DEPLOYED Go Scionic Merkle Tree implementation (v2.2.6 — the version pinned
// by HORNETS-Nostr-Relay and hdk-nostr-go) computes for the exact deterministic
// fixtures defined in src/testutil/Fixtures.swift. These are the authoritative
// expectations behind tests/tests/FixtureRootParityTests.swift.
//
// Chunked-file DAG roots are PLATFORM-OF-CREATION dependent upstream: Go names
// chunk leaves with filepath.Join(relPath, strconv.Itoa(i)) (dag/dag.go), so the
// same bytes chunk-join with '\' on Windows and '/' on Unix and produce
// different CIDs. Unchunked fixtures are platform-independent because file
// relPaths are '/'-normalized on every platform. FixtureRootParityTests.swift
// therefore pins per-platform roots for the chunked fixtures. Regenerate with:
//
//   cd tools/gofixtureroots
//   go mod tidy && go run .        (run on each platform of interest)
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"

	scionic "github.com/HORNET-Storage/Scionic-Merkle-Tree/v2/dag"
)

type fileSpec struct {
	rel  string // '/'-separated; converted with filepath.FromSlash when written
	size int
}

type fixture struct {
	name  string
	files []fileSpec
}

// Mirrors src/testutil/Fixtures.swift exactly (which itself ports the Go
// library's testutil/fixtures.go): content bytes are 'A' + (i % 26).
func deterministicContent(size int) []byte {
	content := make([]byte, size)
	for i := 0; i < size; i++ {
		content[i] = byte('A' + (i % 26))
	}
	return content
}

var fixtures = []fixture{
	{name: "single_small_file", files: []fileSpec{
		{"small.txt", 1024},
	}},
	{name: "single_large_file", files: []fileSpec{
		{"large.txt", 10 * 1024},
	}},
	{name: "flat_directory", files: []fileSpec{
		{"file1.txt", 512},
		{"file2.txt", 1024},
		{"file3.txt", 768},
		{"file4.txt", 2048},
		{"file5.txt", 256},
	}},
	{name: "nested_directory", files: []fileSpec{
		{"subdir1/file1a.txt", 1024},
		{"subdir1/file1b.txt", 1536},
		{"subdir2/file2a.txt", 1024},
		{"subdir2/file2b.txt", 1536},
	}},
	{name: "deep_hierarchy", files: []fileSpec{
		{"level1/file_at_level_1.txt", 256},
		{"level1/level2/file_at_level_2.txt", 512},
		{"level1/level2/level3/file_at_level_3.txt", 768},
		{"level1/level2/level3/level4/file_at_level_4.txt", 1024},
		{"level1/level2/level3/level4/level5/file_at_level_5.txt", 1280},
	}},
	{name: "mixed_sizes", files: []fileSpec{
		{"tiny.txt", 128},
		{"small.txt", 2048},
		{"medium.txt", 5 * 1024},
		{"large.txt", 15 * 1024},
		{"exact_chunk.txt", 4 * 1024},
	}},
}

func main() {
	scionic.SetChunkSize(4096)

	base, err := os.MkdirTemp("", "gofixtureroots")
	must(err)
	defer os.RemoveAll(base)

	for _, f := range fixtures {
		// The DAG root leaf takes the directory's base name, so the fixture
		// directory must be named exactly after the fixture.
		dir := filepath.Join(base, f.name)
		for _, spec := range f.files {
			path := filepath.Join(dir, filepath.FromSlash(spec.rel))
			must(os.MkdirAll(filepath.Dir(path), 0o755))
			must(os.WriteFile(path, deterministicContent(spec.size), 0o644))
		}

		built, err := scionic.CreateDag(dir, false)
		must(err)
		must(built.Verify())

		rootLeaf := built.Leafs[built.Root]
		if rootLeaf == nil {
			panic("root leaf missing for " + f.name)
		}
		chunks := 0
		for _, leaf := range built.Leafs {
			if leaf.Type == scionic.ChunkLeafType {
				chunks++
			}
		}

		fmt.Printf("%-20s root=%s leaves=%d chunks=%d contentSize=%d dagSize=%d\n",
			f.name, built.Root, len(built.Leafs), chunks, rootLeaf.ContentSize, rootLeaf.DagSize)
	}

	fmt.Printf("separator=%q os=%s library=%s\n", string(filepath.Separator), runtime.GOOS, scionicVersion())
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

func must(err error) {
	if err != nil {
		panic(err)
	}
}
