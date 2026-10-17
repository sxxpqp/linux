package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var versionPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

type kindOptions struct{ version, binDir, base, platform, arch string }

func kindAsset(platform, arch string) (string, string, error) {
	if (platform != "linux" && platform != "darwin" && platform != "windows") ||
		(arch != "amd64" && arch != "arm64") || (platform == "windows" && arch != "amd64") {
		return "", "", fmt.Errorf("不支持的 kind 发布平台: %s/%s", platform, arch)
	}
	binary := "kind"
	if platform == "windows" {
		binary += ".exe"
	}
	return "kind-" + platform + "-" + arch, binary, nil
}

func verifyKind(ctx context.Context, path, version string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, path, "version").CombinedOutput()
	if err != nil {
		return fmt.Errorf("运行 kind version 失败: %w: %s", err, output)
	}
	fields := strings.Fields(string(output))
	if len(fields) < 2 || fields[0] != "kind" || fields[1] != version {
		return fmt.Errorf("kind 版本不匹配，要求 %s，返回 %s", version, strings.TrimSpace(string(output)))
	}
	return nil
}

func download(ctx context.Context, source string, destination io.Writer) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("下载 %s: HTTP %d", source, resp.StatusCode)
	}
	_, err = io.Copy(destination, resp.Body)
	return err
}

func installKind(ctx context.Context, o kindOptions, out io.Writer) error {
	if !versionPattern.MatchString(o.version) {
		return errors.New("版本须为 vX.Y.Z")
	}
	asset, binary, err := kindAsset(o.platform, o.arch)
	if err != nil {
		return err
	}
	u, err := url.Parse(o.base)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return errors.New("download-base 必须是 HTTP(S) 地址")
	}
	dir, err := filepath.Abs(o.binDir)
	if err != nil {
		return err
	}
	target := filepath.Join(dir, binary)
	if info, err := os.Lstat(target); err == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("安装目标不是普通文件: %s", target)
		}
		if verifyKind(ctx, target, o.version) == nil {
			fmt.Fprintf(out, "kind 已安装: %s (%s)\n", target, o.version)
			return nil
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	work, err := os.MkdirTemp(dir, ".kind-install-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	source := strings.TrimRight(o.base, "/") + "/kubernetes-sigs/kind/releases/download/" + o.version + "/" + asset
	fmt.Fprintf(out, "下载 kind %s (%s/%s)\n", o.version, o.platform, o.arch)
	var checksum strings.Builder
	if err := download(ctx, source+".sha256sum", &checksum); err != nil {
		return err
	}
	fields := strings.Fields(checksum.String())
	if len(fields) == 0 {
		return errors.New("SHA256 文件为空")
	}
	expected, err := hex.DecodeString(fields[0])
	if err != nil || len(expected) != sha256.Size {
		return errors.New("SHA256 文件格式错误")
	}
	file := filepath.Join(work, binary)
	f, err := os.OpenFile(file, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0755)
	if err != nil {
		return err
	}
	hash := sha256.New()
	downloadErr := download(ctx, source, io.MultiWriter(f, hash))
	closeErr := f.Close()
	if downloadErr != nil {
		return downloadErr
	}
	if closeErr != nil {
		return closeErr
	}
	if hex.EncodeToString(hash.Sum(nil)) != hex.EncodeToString(expected) {
		return errors.New("SHA256 校验失败，未安装，原文件保持不变")
	}
	if err := verifyKind(ctx, file, o.version); err != nil {
		return err
	}
	// 验证成功后再替换；备份保留在同一目录，失败时恢复。
	backup := ""
	if _, err := os.Stat(target); err == nil {
		b, err := os.CreateTemp(dir, "kind.backup-*")
		if err != nil {
			return err
		}
		backup = b.Name()
		if err := b.Close(); err != nil {
			return err
		}
		if err := os.Remove(backup); err != nil {
			return err
		}
		if err := os.Rename(target, backup); err != nil {
			return err
		}
	}
	if err := os.Rename(file, target); err != nil {
		if backup != "" {
			if restoreErr := os.Rename(backup, target); restoreErr != nil {
				return fmt.Errorf("安装失败: %v；恢复失败: %v；原文件在 %s", err, restoreErr, backup)
			}
		}
		return err
	}
	fmt.Fprintf(out, "安装完成: %s (%s)\n", target, o.version)
	if backup != "" {
		fmt.Fprintln(out, "原版本备份:", backup)
	}
	return nil
}
