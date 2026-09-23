package installer

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"rustdesk_install/internal/archive"
	"rustdesk_install/internal/downloader"
	"rustdesk_install/internal/fsops"
	"rustdesk_install/internal/netutil"
	"rustdesk_install/internal/prompt"
	"rustdesk_install/internal/systemd"
	"rustdesk_install/internal/util"
	"strings"
	"time"
)

func Run() {
	showBanner()
	if os.Geteuid() != 0 {
		util.PrintErr("需要 root 权限运行")
		os.Exit(1)
	}

	arch, archiveName, err := detectArch()
	must(err)

	installDir := "/opt/rustdesk"
	logDir := "/var/log/rustdesk"
	systemdDir := "/etc/systemd/system"
	downloadURL := "https://github.com/Chr0mX/rustdesk-server/releases/download/1.1.16-1/rustdesk-server-linux-amd64.zip" 

	if isInstalled(installDir) {
		op := prompt.Menu("检测到已安装，选择操作：", []string{"覆盖安装", "卸载", "取消"})
		switch op {
		case 1:
		case 2:
			uninstall(installDir, logDir, systemdDir)
			util.PrintInfo("已卸载")
			return
		default:
			util.PrintInfo("已取消")
			return
		}
	}

	mode := prompt.Menu("部署方式", []string{"公网IP", "域名（DDNS）", "内网手动IP"})
	var idAddr string
	switch mode {
	case 1:
		wan, _ := netutil.GetWANIP()
		if wan == "" {
			util.PrintErr("无法获取公网IP")
			os.Exit(1)
		}
		idAddr = wan
	case 2:
		domain := prompt.Input("输入域名：", "")
		ips, _ := netutil.LookupDomainIPs(domain)
		if len(ips) == 0 {
			util.PrintErr("域名解析失败")
			os.Exit(1)
		}
		wan, _ := netutil.GetWANIP()
		if wan != "" && !contains(ips, wan) {
			if !prompt.YesNo("解析IP与本地出口IP不一致，仍继续？") {
				os.Exit(1)
			}
		}
		idAddr = domain
	case 3:
		lan := prompt.Input("输入静态IP：", "")
		idAddr = lan
	}

	hbsPort := "21116"
	hbrPort := "21117"

	must(os.MkdirAll(installDir, 0755))
	must(os.MkdirAll(logDir, 0755))

	util.PrintInfo("正在下载 %s (%s) ...", archiveName, arch)
	must(downloader.DownloadWithProgress(downloadURL, archiveName, archiveName))
	must(archive.Unzip(archiveName, installDir))
	must(fsops.MoveBins(installDir))
	must(os.Chmod(filepath.Join(installDir, "hbbs"), 0755))
	must(os.Chmod(filepath.Join(installDir, "hbbr"), 0755))
	_ = os.Remove(archiveName)

	if systemd.HasSystemctl() {
		util.PrintInfo("正在配置并启动系统服务...")
		must(util.WriteFile(filepath.Join(systemdDir, "rustdesksignal.service"), systemd.SignalUnit(installDir, logDir, hbsPort, idAddr, hbrPort)))
		must(util.WriteFile(filepath.Join(systemdDir, "rustdeskrelay.service"), systemd.RelayUnit(installDir, logDir, hbrPort)))
		must(systemd.EnableAndStart())
	} else {
		util.PrintInfo("正在启动后台进程...")
		must(util.StartDetached(filepath.Join(installDir, "hbbs"), []string{"-p", hbsPort, "-r", idAddr + ":" + hbrPort}, filepath.Join(logDir, "signal.log"), installDir))
		must(util.StartDetached(filepath.Join(installDir, "hbbr"), []string{"-p", hbrPort}, filepath.Join(logDir, "relay.log"), installDir))
	}

	time.Sleep(2 * time.Second)
	pubKey := util.ReadPubKey(installDir)
	idDisplay := idAddr
	if hbsPort != "21116" {
		idDisplay = idAddr + ":" + hbsPort
	}
	util.PrintInfo("安装完成！")
	fmt.Println()
	relayDisplay := idAddr
	fmt.Println(util.Purple + "================================================================" + util.Reset)

	printKV := func(key, val, color string) {
		width := 0
		for _, r := range key {
			if r > 127 {
				width += 2
			} else {
				width += 1
			}
		}
		pad := 16 - width
		if pad < 0 {
			pad = 0
		}
		padding := strings.Repeat(" ", pad)
		fmt.Printf(util.White+" %s%s : "+util.Reset+color+"%s"+util.Reset+"\n", key, padding, val)
	}

	printKV("ID服务器地址", idDisplay, util.Green)
	printKV("中继服务器地址", relayDisplay, util.Green)
	printKV("Key", pubKey, util.Yellow)
	printKV("日志目录", logDir, util.Cyan)
	fmt.Println(util.Purple + "================================================================" + util.Reset)
	fmt.Println()

	fmt.Println(util.Purple + "启动与关闭命令：" + util.Reset)
	if systemd.HasSystemctl() {
		printKV("启动", "systemctl start rustdesksignal rustdeskrelay", util.Reset)
		printKV("停止", "systemctl stop rustdesksignal rustdeskrelay", util.Reset)
		printKV("重启", "systemctl restart rustdesksignal rustdeskrelay", util.Reset)
	} else {
		printKV("启动", "手动运行 hbbs/hbbr", util.Reset)
		printKV("停止", "pkill hbbs && pkill hbbr", util.Reset)
	}
	fmt.Println()
}

func isInstalled(dir string) bool {
	if _, err := os.Stat(filepath.Join(dir, "hbbs")); err == nil {
		if _, err2 := os.Stat(filepath.Join(dir, "hbbr")); err2 == nil {
			return true
		}
	}
	return false
}

func uninstall(installDir, logDir, systemdDir string) {
	if systemd.HasSystemctl() {
		_ = systemd.DisableAndStop()
		_ = systemd.RemoveUnits(systemdDir)
	} else {
		_ = util.RunCommand("pkill", "hbbs")
		_ = util.RunCommand("pkill", "hbbr")
	}
	_ = os.RemoveAll(installDir)
	_ = os.RemoveAll(logDir)
}

func detectArch() (string, string, error) {
	out, err := exec.Command("uname", "-m").Output()
	if err != nil {
		return "", "", err
	}
	arch := strings.TrimSpace(string(out))
	switch arch {
	case "x86_64":
		return arch, "rustdesk-server-linux-amd64.zip", nil
	case "aarch64":
		return arch, "rustdesk-server-linux-arm64v8.zip", nil
	case "armv7l":
		return arch, "rustdesk-server-linux-armv7.zip", nil
	default:
		return arch, "", errors.New("不支持架构 " + arch)
	}
}

func contains(arr []string, s string) bool {
	for _, v := range arr {
		if v == s {
			return true
		}
	}
	return false
}

func must(err error) {
	if err != nil {
		util.PrintErr(err.Error())
		os.Exit(1)
	}
}

func showBanner() {
	encodedBanner := "CiAgICBfICAgX18gICAgICAgICAgICBfX19fX18gICAgICAgICAgICBfXwogICAvIHwgLyAvX19fIF9fX19fXyAvXyAgX18vX19fICBfX19fICAvIC8KICAvICB8LyAvIF9fICAvIF9fXy8gIC8gLyAvIF9fIFwvIF9fIFwvIC8gCiAvIC98ICAvIC9fLyAoX18gICkgIC8gLyAvIC9fLyAvIC9fLyAvIC8gIAovXy8gfF8vXF9fLF8vX19fXy8gIC9fLyAgXF9fX18vXF9fX18vXy8gICAKCiBSdXN0RGVzayDkuIDplK7lronoo4XohJrmnKwKIFBvd2VyZWQgYnkgaHR0cHM6Ly9uYXMtdG9vbC5jb20KIAog5L2c6ICFMe+8mndhbmdoYW95dS5jb20uY24gICjpl7LpsbzvvJrln7rnoYDnvZHnu5zov5Dnu7QpCiDkvZzogIUy77yaZWNobzIzNC5jbiAgICAgICAgKOmXsumxvO+8mk5BU+a9rumbhikK"
	expectedHash := util.GetChecksum()

	banner, err := base64.StdEncoding.DecodeString(encodedBanner)
	if err != nil {
		util.PrintCyan("RustDesk Installer")
		return
	}

	hash := sha256.Sum256(banner)
	if fmt.Sprintf("%x", hash) != expectedHash {
		util.PrintErr("Error: Logo has been tampered with!")
		os.Exit(1)
	}

	util.PrintCyan(string(banner))
}
