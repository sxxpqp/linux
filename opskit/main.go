// opskit 将重复的运维操作集中为跨平台命令。当前迁移范围：指定版本安装 kind。
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run(args []string, out io.Writer) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" {
		fmt.Fprintln(out, "用法: opskit kind install --version v0.17.0 [--bin-dir DIR] [--download-base URL]")
		fmt.Fprintln(out, "默认安装到 ~/.local/share/opskit/kind/<版本>/，不同版本互不覆盖。")
		return nil
	}
	if len(args) < 2 || args[0] != "kind" || args[1] != "install" {
		return errors.New("未知命令，请运行 opskit --help")
	}
	f := flag.NewFlagSet("kind install", flag.ContinueOnError)
	f.SetOutput(out)
	version := f.String("version", "", "必填，kind 版本，例如 v0.17.0")
	binDir := f.String("bin-dir", "", "安装目录，默认按版本隔离")
	base := f.String("download-base", defaultDownloadBase(), "发布包下载源（默认 Nexus，支持 https://github.com）")
	if err := f.Parse(args[2:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if f.NArg() != 0 {
		return errors.New("存在多余参数，请使用 --version 指定版本")
	}
	if !versionPattern.MatchString(*version) {
		return errors.New("必须指定 --version vX.Y.Z")
	}
	if *binDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		*binDir = filepath.Join(home, ".local", "share", "opskit", "kind", *version)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	return installKind(ctx, kindOptions{*version, *binDir, *base, runtime.GOOS, runtime.GOARCH}, out)
}

func defaultDownloadBase() string {
	if base := os.Getenv("KIND_DOWNLOAD_BASE"); base != "" {
		return base
	}
	return "https://nexus.ihome.sxxpqp.top:8443/repository/raw-github"
}
