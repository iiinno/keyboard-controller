package main

import (
    "bytes"
    "os"
    "path/filepath"
    "runtime"
    "strings"
    "testing"
)

func TestConfigRoundTripAndPreservation(t *testing.T) {
    c,_:=fixture(t)
    path:=filepath.Join(t.TempDir(),"with spaces","config.json")
    if err:=saveConfig(path,c.cfg,false);err!=nil{t.Fatal(err)}
    got,err:=loadConfig(path);if err!=nil||got!=c.cfg{t.Fatalf("round trip: %v %v",got,err)}
    if err=saveConfig(path,c.cfg,false);err==nil{t.Fatal("overwrote an existing config")}
    replacement:=c.cfg;replacement.PollMS=2000
    if err=saveConfig(path,replacement,true);err!=nil{t.Fatal(err)}
    got,err=loadConfig(path);if err!=nil||got.PollMS!=2000{t.Fatal("replacement was not applied")}
    info,err:=os.Stat(path);if err!=nil||info.Mode().Perm()!=0600{t.Fatal("config must be owner-only")}
}

func TestConfigRejectsInvalidAndTrailingData(t *testing.T) {
    c,_:=fixture(t)
    for _,kind:=range []string{"version","platform","same","empty","poll","settle"}{t.Run(kind,func(t *testing.T){cfg:=c.cfg
        switch kind{case "version":cfg.Version=2;case "platform":cfg.Platform="unsupported";case "same":cfg.ExternalID=cfg.InternalID;case "empty":cfg.InternalID="";case "poll":cfg.PollMS=0;case "settle":cfg.SettleMS=-1}
        if cfg.Validate()==nil{t.Fatal("invalid config accepted")}
    })}
    path:=filepath.Join(t.TempDir(),"config.json")
    if err:=saveConfig(path,c.cfg,false);err!=nil{t.Fatal(err)}
    f,err:=os.OpenFile(path,os.O_APPEND|os.O_WRONLY,0600);if err!=nil{t.Fatal(err)};f.WriteString("{}\n");f.Close()
    if _,err=loadConfig(path);err==nil{t.Fatal("trailing data accepted")}
    os.WriteFile(path,[]byte(`{"unknown":true}`),0600)
    if _,err=loadConfig(path);err==nil{t.Fatal("unknown field accepted")}
    if _,err=loadConfig(path+"missing");err==nil{t.Fatal("missing config accepted")}
}

func TestGuidedSetup(t *testing.T) {
    _,f:=fixture(t);var out bytes.Buffer
    path:=filepath.Join(t.TempDir(),"config.json")
    if err:=setup(strings.NewReader("1\n2\n"),&out,f.devices,path,false);err!=nil{t.Fatal(err)}
    cfg,err:=loadConfig(path);if err!=nil||cfg.InternalID!="internal"||cfg.ExternalID!="external"||cfg.Platform!=runtime.GOOS{t.Fatal("wrong setup selection")}
    for _,text:=range []string{"0\n2\n","1\n1\n","bad\n",""}{
        if err=setup(strings.NewReader(text),&out,f.devices,filepath.Join(t.TempDir(),"config.json"),false);err==nil{t.Fatalf("invalid selection accepted: %q",text)}
    }
    f.devices[0].Blockable=false
    if setup(strings.NewReader("1\n2\n"),&out,f.devices,path,true)==nil{t.Fatal("composite internal keyboard accepted")}
    if setup(strings.NewReader(""),&out,nil,path,true)==nil{t.Fatal("missing devices accepted")}
}

func TestNativeReadOnlyDiagnostics(t *testing.T) {
    b,err:=newBackend();if err!=nil{t.Fatal(err)}
    defer b.Release()
    if _,err=b.Devices();err!=nil{t.Fatal(err)}
    if b.NowMS()<=0{t.Fatal("invalid uptime clock")}
    if b.PermissionStatus()==""{t.Fatal("missing permission instructions")}
    if b.Grab(Device{})==nil{t.Fatal("invalid device accepted")}
    if err=b.Pump(0);err!=nil{t.Fatal(err)}
    if err=b.Release();err!=nil{t.Fatal(err)}
    var out bytes.Buffer
    for _,args:=range [][]string{{"--help"},{"version"},{"devices","--json"},{"devices","--help"}}{
        if err=entry(args,strings.NewReader(""),&out);err!=nil{t.Fatalf("%v: %v",args,err)}
    }
    if entry([]string{"invalid"},strings.NewReader(""),&out)==nil{t.Fatal("bad command accepted")}
    if entry([]string{"devices","extra"},strings.NewReader(""),&out)==nil{t.Fatal("extra argument accepted")}
}

func TestRunQuitReleases(t *testing.T) {
    c,f:=fixture(t);c.cfg.SettleMS=0
    var out bytes.Buffer
    if err:=run(f,c.cfg,strings.NewReader("status\non\nauto\npause 5\npause 15\nquit\n"),&out,false,false);err!=nil{t.Fatal(err)}
    if f.grabbed!=""{t.Fatal("run returned holding a grab")}
}

func TestEightSecondTestRequiresExternal(t *testing.T) {
    c,f:=fixture(t);f.devices=f.devices[:1]
    var out bytes.Buffer
    err:=run(f,c.cfg,strings.NewReader(""),&out,false,true)
    if err==nil||!strings.Contains(err.Error(),"did not start")||f.grabs!=0{t.Fatalf("test without external: %v grabs=%d",err,f.grabs)}
}
