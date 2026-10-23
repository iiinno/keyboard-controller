package main

import (
	"errors"
	"runtime"
	"testing"
	"time"
)

type fakeBackend struct {
	now                          int64
	devices                      []Device
	listErr, grabErr, releaseErr error
	grabbed                      string
	grabs, releases              int
}

func (f *fakeBackend) Devices() ([]Device, error) { return f.devices, f.listErr }
func (f *fakeBackend) Grab(d Device) error {
	if f.grabErr != nil {
		return f.grabErr
	}
	f.grabbed = d.Locator
	f.grabs++
	return nil
}
func (f *fakeBackend) Release() error {
	f.releases++
	if f.releaseErr != nil {
		return f.releaseErr
	}
	f.grabbed = ""
	return nil
}
func (f *fakeBackend) Pump(time.Duration) error                       { return nil }
func (f *fakeBackend) NowMS() int64                                   { return f.now }
func (f *fakeBackend) PermissionStatus() string                       { return "fake" }
func (f *fakeBackend) RequestPermission(Config, bool) (string, error) { return "fake", nil }

func fixture(t *testing.T) (*Controller, *fakeBackend) {
	t.Helper()
	f := &fakeBackend{now: 100000, devices: []Device{{ID: "internal", Name: "internal", Locator: "internal-1", Blockable: true}, {ID: "external", Name: "external", Locator: "external-1", Blockable: true}}}
	c, err := newController(f, Config{Version: 1, Platform: runtime.GOOS, InternalID: "internal", ExternalID: "external", PollMS: 1000, SettleMS: 3000})
	if err != nil {
		t.Fatal(err)
	}
	return c, f
}
func tick(t *testing.T, c *Controller, f *fakeBackend, ms int64) {
	t.Helper()
	f.now += ms
	if err := c.Tick(); err != nil {
		t.Fatal(err)
	}
}
func state(t *testing.T, c *Controller, want string) {
	t.Helper()
	if c.State != want {
		t.Fatalf("state=%s want=%s (%s)", c.State, want, c.Reason)
	}
}

func TestStartupDisconnectAndRelease(t *testing.T) {
	c, f := fixture(t)
	tick(t, c, f, 0)
	state(t, c, "PASS")
	tick(t, c, f, 3000)
	state(t, c, "BLOCKED")
	f.devices = f.devices[:1]
	tick(t, c, f, 1000)
	state(t, c, "PASS")
	if f.grabbed != "" {
		t.Fatal("grab retained")
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	if f.releases != 1 {
		t.Fatalf("releases=%d", f.releases)
	}
}
func TestUnknownAndAmbiguousFailOpen(t *testing.T) {
	for _, kind := range []string{"enumeration", "missing-internal", "ambiguous-internal", "ambiguous-external", "pointer"} {
		t.Run(kind, func(t *testing.T) {
			c, f := fixture(t)
			tick(t, c, f, 3000)
			state(t, c, "BLOCKED")
			switch kind {
			case "enumeration":
				f.listErr = errors.New("injected")
			case "missing-internal":
				f.devices = f.devices[1:]
			case "ambiguous-internal":
				f.devices = append(f.devices, f.devices[0])
			case "ambiguous-external":
				f.devices = append(f.devices, f.devices[1])
			case "pointer":
				f.devices[0].Blockable = false
			}
			tick(t, c, f, 1000)
			state(t, c, "PASS")
			if f.grabbed != "" {
				t.Fatal("unsafe grab retained")
			}
		})
	}
}
func TestTemporaryPassAndFreshExpiry(t *testing.T) {
	c, f := fixture(t)
	tick(t, c, f, 3000)
	if err := c.Pause(5 * time.Minute); err != nil {
		t.Fatal(err)
	}
	state(t, c, "PASS")
	for i := 0; i < 299; i++ {
		tick(t, c, f, 1000)
		state(t, c, "PASS")
	}
	tick(t, c, f, 1000)
	state(t, c, "BLOCKED")
	if err := c.Pause(15 * time.Minute); err != nil {
		t.Fatal(err)
	}
	f.devices = f.devices[:1]
	for i := 0; i < 900; i++ {
		tick(t, c, f, 1000)
	}
	state(t, c, "PASS")
	if c.Pause(0) == nil || c.Pause(2*time.Hour) == nil {
		t.Fatal("bad duration accepted")
	}
}
func TestExplicitModesAndResume(t *testing.T) {
	c, f := fixture(t)
	tick(t, c, f, 3000)
	if err := c.SetMode("FORCED_ON"); err != nil {
		t.Fatal(err)
	}
	state(t, c, "PASS")
	if err := c.SetMode("AUTO"); err != nil {
		t.Fatal(err)
	}
	tick(t, c, f, 0)
	state(t, c, "BLOCKED")
	tick(t, c, f, 100000)
	state(t, c, "PASS")
	tick(t, c, f, 2999)
	state(t, c, "PASS")
	tick(t, c, f, 1)
	state(t, c, "BLOCKED")
	if err := c.SetMode("invalid"); err == nil {
		t.Fatal("invalid mode accepted")
	}
}
func TestReopenedDeviceGetsNewHandle(t *testing.T) {
	c, f := fixture(t)
	tick(t, c, f, 3000)
	f.devices[0].Locator = "internal-2"
	tick(t, c, f, 1000)
	if f.grabbed != "internal-2" || f.releases != 1 {
		t.Fatal("old device handle reused")
	}
}
func TestFailuresNeverClaimPass(t *testing.T) {
	c, f := fixture(t)
	f.grabErr = errors.New("grab failed")
	f.now += 3000
	if c.Tick() == nil {
		t.Fatal("grab failure swallowed")
	}
	state(t, c, "PASS")
	c, f = fixture(t)
	tick(t, c, f, 3000)
	f.releaseErr = errors.New("release failed")
	if c.Close() == nil {
		t.Fatal("release failure swallowed")
	}
	state(t, c, "UNKNOWN")
}
