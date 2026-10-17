package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestAssets(t *testing.T) {
	for _, platform := range []string{"linux", "darwin", "windows"} {
		for _, arch := range []string{"amd64", "arm64"} {
			asset, binary, err := kindAsset(platform, arch)
			if platform == "windows" && arch == "arm64" {
				if err == nil {
					t.Fatal("Windows arm64 should be rejected")
				}
				continue
			}
			if err != nil || asset != "kind-"+platform+"-"+arch {
				t.Fatalf("bad asset: %s %v", asset, err)
			}
			if (platform == "windows") != strings.HasSuffix(binary, ".exe") {
				t.Fatal("wrong executable suffix")
			}
		}
	}
}

func TestVersionRequired(t *testing.T) {
	for _, args := range [][]string{
		{"kind", "install"}, {"kind", "install", "--version", "latest"},
		{"kind", "install", "--version", "../../bad"}, {"kind", "install", "--version", "v0.17.0", "extra"},
	} {
		if run(args, io.Discard) == nil {
			t.Fatalf("accepted invalid args: %v", args)
		}
	}
}

func TestInstallVersionsAndFailures(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture is a POSIX executable; Windows builds are checked separately")
	}
	version := "v0.17.0"
	corrupt := false
	wrongVersion := false
	notFound := false
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if notFound {
			http.NotFound(w, r)
			return
		}
		printed := version
		if wrongVersion {
			printed = "v0.1.0"
		}
		payload := []byte("#!/bin/sh\necho 'kind " + printed + " mock'\n")
		if strings.HasSuffix(r.URL.Path, ".sha256sum") {
			if corrupt {
				payload = []byte("different")
			}
			fmt.Fprintf(w, "%x  kind\n", sha256.Sum256(payload))
		} else {
			_, _ = w.Write(payload)
		}
	}))
	defer server.Close()
	root := t.TempDir()
	install := func(dir string) error {
		return installKind(context.Background(), kindOptions{version, dir, server.URL, runtime.GOOS, runtime.GOARCH}, io.Discard)
	}
	first := filepath.Join(root, version)
	if err := install(first); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(filepath.Join(first, "kind"))
	if err != nil {
		t.Fatal(err)
	}
	count := requests
	if err := install(first); err != nil || count != requests {
		t.Fatal("same version should skip downloads", err)
	}
	version = "v0.33.0"
	second := filepath.Join(root, version)
	if err := install(second); err != nil {
		t.Fatal(err)
	}
	if err := verifyKind(context.Background(), filepath.Join(first, "kind"), "v0.17.0"); err != nil {
		t.Fatal("old version was overwritten", err)
	}
	for _, mode := range []string{"checksum", "version", "HTTP"} {
		corrupt, wrongVersion, notFound = mode == "checksum", mode == "version", mode == "HTTP"
		if err := install(first); err == nil {
			t.Fatalf("expected %s failure", mode)
		}
		current, err := os.ReadFile(filepath.Join(first, "kind"))
		if err != nil || !bytes.Equal(current, original) {
			t.Fatalf("%s failure modified original", mode)
		}
	}
	corrupt, wrongVersion, notFound = false, false, false
	if err := install(first); err != nil {
		t.Fatal(err)
	}
	backups, _ := filepath.Glob(filepath.Join(first, "kind.backup-*"))
	if len(backups) != 1 {
		t.Fatal("replacement must keep original backup")
	}
	backup, err := os.ReadFile(backups[0])
	if err != nil || !bytes.Equal(backup, original) {
		t.Fatal("backup does not match old binary")
	}
}
