package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

type testTransport func(*http.Request) (*http.Response, error)

func (f testTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestInstallGeoIPVerifiesChecksumAndKeepsExistingOnFailure(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.xdb")
	require.NoError(t, os.WriteFile(path, []byte("previous"), 0600))
	data := "verified database"
	digest := sha256.Sum256([]byte(data))
	expected := hex.EncodeToString(digest[:])
	calls := 0
	client := &http.Client{Transport: testTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		require.Equal(t, "https://raw.githubusercontent.com/lionsoul2014/ip2region/"+revision+"/data/test.xdb", r.URL.String())
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(data))}, nil
	})}
	require.Error(t, install(client, dir, "test.xdb", "wrong hash"))
	old, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, "previous", string(old))
	require.NoError(t, install(client, dir, "test.xdb", expected))
	require.Equal(t, 2, calls)
	require.NoError(t, install(client, dir, "test.xdb", expected))
	require.Equal(t, 2, calls)
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	require.Len(t, entries, 1)
}
