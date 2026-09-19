package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Linux input_event 16-byte struct on 32-bit ARM:
// struct input_event {
//     struct timeval time; // 8 bytes: 4 sec + 4 usec
//     __u16 type;          // 2 bytes
//     __u16 code;          // 2 bytes
//     __s32 value;         // 4 bytes
// };
type inputEvent struct {
	TimeSec  uint32
	TimeUsec uint32
	Type     uint16
	Code     uint16
	Value    int32
}

const (
	EV_SYN = 0x00
	EV_KEY = 0x01
	EV_ABS = 0x03

	BTN_TOUCH          = 0x014a // 330
	ABS_X              = 0x00
	ABS_Y              = 0x01
	ABS_MT_POSITION_X  = 0x35 // 53
	ABS_MT_POSITION_Y  = 0x36 // 54
	ABS_MT_TRACKING_ID = 0x39 // 57

	// EVIOCGRAB ioctl (_IOW('E', 0x90, int)) to grab evdev device exclusively
	EVIOCGRAB = 0x40044590

// Physical portrait dimensions of Kindle Paperwhite 3 digitizer
	HwWidth  = 1072
	HwHeight = 1448
)

func findTouchDevice() string {
	// Check /proc/bus/input/devices first
	data, err := os.ReadFile("/proc/bus/input/devices")
	if err == nil {
		blocks := strings.Split(string(data), "\n\n")
		for _, block := range blocks {
			lower := strings.ToLower(block)
			if strings.Contains(lower, "touch") || strings.Contains(lower, "zforce") ||
				strings.Contains(lower, "elan") || strings.Contains(lower, "cyttsp") ||
				strings.Contains(lower, "wacom") {
				for _, line := range strings.Split(block, "\n") {
					line = strings.TrimSpace(line)
					if strings.HasPrefix(line, "H: Handlers=") {
						for _, field := range strings.Fields(line) {
							if strings.HasPrefix(field, "event") {
								path := "/dev/input/" + field
								if _, err := os.Stat(path); err == nil {
									log.Printf("[Touch Listener] Auto-detected touchscreen device: %s", path)
									return path
								}
							}
						}
					}
				}
			}
		}
	}

	// Fallback check: Kindle PW3 digitizer is almost always event1
	if _, err := os.Stat("/dev/input/event1"); err == nil {
		log.Printf("[Touch Listener] Using fallback touchscreen device: /dev/input/event1")
		return "/dev/input/event1"
	}
	return "/dev/input/event0"
}

func grabDevice(fd uintptr, grab bool) error {
	val := uintptr(0)
	if grab {
		val = uintptr(1)
	}
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(EVIOCGRAB), val)
	if errno != 0 {
		return errno
	}
	return nil
}

type Config struct {
	ServerURL    string
	Rotation     int
	EventDevice  string
	DashboardBin string
}

func loadConfig(path string) Config {
	cfg := Config{
		ServerURL:    "https://www.forusers.com",
		Rotation:     90,
		EventDevice:  findTouchDevice(),
		DashboardBin: "/mnt/us/dashboard/dashboard.sh",
	}

	f, err := os.Open(path)
	if err != nil {
		return cfg
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.Trim(strings.TrimSpace(parts[1]), `"'`)

		switch key {
		case "SERVER_URL":
			cfg.ServerURL = val
		case "ROTATION":
			if r, err := strconv.Atoi(val); err == nil {
				cfg.Rotation = r
			}
		case "EVENT_DEVICE":
			cfg.EventDevice = val
		case "DASHBOARD_SCRIPT":
			cfg.DashboardBin = val
		}
	}
	return cfg
}

func translateCoordinates(hwX, hwY, rotation int) (int, int) {
	// Clamp hardware coordinates
	if hwX < 0 {
		hwX = 0
	} else if hwX >= HwWidth {
		hwX = HwWidth - 1
	}
	if hwY < 0 {
		hwY = 0
	} else if hwY >= HwHeight {
		hwY = HwHeight - 1
	}

	switch rotation {
	case 90:
		// Landscape (USB on the RIGHT)
		// Physical top is right edge, physical bottom is left edge
		// X_land = Y_hw
		// Y_land = (HwWidth - 1) - X_hw
		return hwY, (HwWidth - 1) - hwX

	case 270:
		// Landscape (USB on the LEFT)
		// X_land = (HwHeight - 1) - Y_hw
		// Y_land = X_hw
		return (HwHeight - 1) - hwY, hwX

	case 180:
		// Inverted Portrait
		return (HwWidth - 1) - hwX, (HwHeight - 1) - hwY

	default:
		// Native Portrait (Rotation 0)
		return hwX, hwY
	}
}

func triggerDashboardRefresh(scriptPath string) {
	log.Printf("[Touch] Triggering dashboard refresh via %s once...", scriptPath)
	cmd := exec.Command("/bin/sh", scriptPath, "once")
	if err := cmd.Start(); err != nil {
		log.Printf("[Touch] Failed to start refresh script: %v", err)
	}
}

func dismissTaskOnServer(serverURL string, taskIndex int) error {
	client := &http.Client{Timeout: 5 * time.Second}
	url := fmt.Sprintf("%s/api/kindle/tasks/dismiss?index=%d", strings.TrimRight(serverURL, "/"), taskIndex)
	log.Printf("[Touch] Sending task dismissal request: POST %s", url)

	req, err := http.NewRequest("POST", url, bytes.NewBuffer([]byte("{}")))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("server returned status %d: %s", resp.StatusCode, string(body))
	}

	log.Printf("[Touch] Task index %d successfully completed on server!", taskIndex)
	return nil
}

func showInstantFeedback(message string) {
	fbinkPath := ""
	for _, p := range []string{"/tmp/fbink", "/mnt/us/dashboard/fbink", "/mnt/us/usbnet/bin/fbink"} {
		if _, err := os.Stat(p); err == nil {
			fbinkPath = p
			break
		}
	}
	if fbinkPath != "" {
		// Render immediate inverted pill banner centered on screen in ~30ms
		_ = exec.Command(fbinkPath, "-pmh", "-M", "0", message).Run()
	}
}

func handleTap(cfg Config, landX, landY int) {
	log.Printf("[Touch] Tap detected at Landscape (X=%d, Y=%d)", landX, landY)

	// Check if tap falls in the SHARED TO-DO & TASKS section
	// Tasks section: X in [525, 1413], Y in [520, 980]
	// Each task card is 66px tall + 8px spacing = 74px pitch
	if landX >= 525 && landX <= 1413 && landY >= 520 && landY <= 980 {
		taskIndex := (landY - 524) / 74
		if taskIndex >= 0 && taskIndex < 6 {
			log.Printf("[Touch] Tap HIT on Task Checkbox [Row %d]! Dismissing task...", taskIndex)

			// 1. Show instant visual feedback (<50ms) so user knows tap was registered
			go showInstantFeedback(fmt.Sprintf("  [✓] Checking Off Task %d...  ", taskIndex+1))

			// 2. Fire dismiss request and trigger fast screen update
			go func(idx int) {
				if err := dismissTaskOnServer(cfg.ServerURL, idx); err != nil {
					log.Printf("[Touch] Warning: Task dismiss API call failed: %v", err)
				}
				// Refresh dashboard to display strikethrough / updated list immediately
				triggerDashboardRefresh(cfg.DashboardBin)
			}(taskIndex)
			return
		}
	}

	// Any other tap (e.g. Weather, Clock, Markets, Schedule) acts as Tap-to-Refresh
	log.Printf("[Touch] Tap on dashboard body -> Refreshing screen...")
	go showInstantFeedback("  ↻ Refreshing Dashboard...  ")
	go triggerDashboardRefresh(cfg.DashboardBin)
}

func main() {
	configPath := flag.String("config", "/mnt/us/dashboard/config.cfg", "Path to dashboard config.cfg")
	deviceFlag := flag.String("dev", "", "Input event device (overrides config)")
	rotationFlag := flag.Int("rotate", -1, "Rotation in degrees (overrides config)")
	serverFlag := flag.String("server", "", "Server URL (overrides config)")
	flag.Parse()

	log.Println("==========================================")
	log.Println("[Touch Listener] Starting Kindle Touch Monitor...")

	cfg := loadConfig(*configPath)
	if *deviceFlag != "" {
		cfg.EventDevice = *deviceFlag
	}
	if *rotationFlag >= 0 {
		cfg.Rotation = *rotationFlag
	}
	if *serverFlag != "" {
		cfg.ServerURL = *serverFlag
	}

	log.Printf("[Touch Listener] Device: %s | Rotation: %d° | Server: %s",
		cfg.EventDevice, cfg.Rotation, cfg.ServerURL)

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("[Touch Listener] Terminating on signal...")
		os.Exit(0)
	}()

	for {
		err := runEventLoop(cfg)
		if err != nil {
			log.Printf("[Touch Listener] Device error: %v. Reconnecting in 3 seconds...", err)
			time.Sleep(3 * time.Second)
		}
	}
}

func runEventLoop(cfg Config) error {
	devFile, err := os.Open(cfg.EventDevice)
	if err != nil {
		return err
	}
	defer devFile.Close()

	// Grab device exclusively so underlying Kindle apps / KUAL do NOT receive touches
	if err := grabDevice(devFile.Fd(), true); err != nil {
		log.Printf("[Touch Listener] Warning: Could not grab %s exclusively (ioctl EVIOCGRAB): %v", cfg.EventDevice, err)
	} else {
		log.Printf("[Touch Listener] Successfully grabbed %s exclusively (shielding underlying UI).", cfg.EventDevice)
		defer grabDevice(devFile.Fd(), false)
	}

	log.Printf("[Touch Listener] Successfully opened %s. Listening for touch events...", cfg.EventDevice)

	var currentHwX int = -1
	var currentHwY int = -1
	var lastTapTime time.Time

	var ev inputEvent
	evSize := binary.Size(ev)
	buf := make([]byte, evSize)

	for {
		_, err := io.ReadFull(devFile, buf)
		if err != nil {
			return err
		}

		err = binary.Read(bytes.NewReader(buf), binary.LittleEndian, &ev)
		if err != nil {
			continue
		}

		switch ev.Type {
		case EV_ABS:
			switch ev.Code {
			case ABS_X, ABS_MT_POSITION_X:
				currentHwX = int(ev.Value)
			case ABS_Y, ABS_MT_POSITION_Y:
				currentHwY = int(ev.Value)
			case ABS_MT_TRACKING_ID:
				if ev.Value == -1 && currentHwX >= 0 && currentHwY >= 0 {
					// Touch lifted (MT tracking released)
					now := time.Now()
					if now.Sub(lastTapTime) > 1500*time.Millisecond {
						lastTapTime = now
						lx, ly := translateCoordinates(currentHwX, currentHwY, cfg.Rotation)
						handleTap(cfg, lx, ly)
					}
				}
			}

		case EV_KEY:
			if ev.Code == BTN_TOUCH {
				if ev.Value == 0 && currentHwX >= 0 && currentHwY >= 0 {
					// Touch lifted (BTN_TOUCH release)
					now := time.Now()
					if now.Sub(lastTapTime) > 1500*time.Millisecond {
						lastTapTime = now
						lx, ly := translateCoordinates(currentHwX, currentHwY, cfg.Rotation)
						handleTap(cfg, lx, ly)
					}
				}
			}
		}
	}
}
