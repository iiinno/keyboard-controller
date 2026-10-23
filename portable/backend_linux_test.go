//go:build linux

package main

import (
    "fmt"
    "os"
    "path/filepath"
    "strings"
    "testing"
)

func capabilities(bits ...int) string {
    words:=make([]uint64,6)
    for _,bit:=range bits{words[bit/64]|=uint64(1)<<uint(bit%64)}
    parts:=[]string{}
    for i:=len(words)-1;i>=0;i--{parts=append(parts,fmt.Sprintf("%016x",words[i]))}
    return strings.Join(parts," ")
}

func TestLinuxCapabilitiesAndSafeEnumeration(t *testing.T) {
    if !keyBit("1 0",64)||keyBit("1 0",0)||keyBit("bad!",1){t.Fatal("kernel word ordering is wrong")}
    root:=t.TempDir();b:=&linuxBackend{sysRoot:filepath.Join(root,"sys"),devRoot:filepath.Join(root,"dev"),fd:-1}
    for i,kind:=range []string{"keyboard","mouse","composite","virtual"}{
        base:=filepath.Join(b.sysRoot,fmt.Sprintf("event%d",i),"device")
        data:=map[string]string{"name":kind,"phys":"isa0060/serio0/input0","uniq":"","id/vendor":"1234","id/product":"5678","id/bustype":"0011","capabilities/key":capabilities(28,30,44),"capabilities/ev":capabilities(0,1)}
        if kind=="mouse"{data["capabilities/key"]=capabilities(272)}
        if kind=="composite"{data["capabilities/ev"]=capabilities(0,1,2)}
        if kind=="virtual"{data["id/bustype"]="0006"}
        for name,value:=range data{path:=filepath.Join(base,name);os.MkdirAll(filepath.Dir(path),0700);if err:=os.WriteFile(path,[]byte(value),0600);err!=nil{t.Fatal(err)}}
    }
    os.MkdirAll(filepath.Join(b.devRoot,"by-path"),0700)
    target:=filepath.Join(b.devRoot,"event0");os.WriteFile(target,nil,0600)
    if err:=os.Symlink(target,filepath.Join(b.devRoot,"by-path","platform-i8042-serio-0-event-kbd"));err!=nil{t.Fatal(err)}
    devices,err:=b.Devices();if err!=nil{t.Fatal(err)}
    if len(devices)!=3||!devices[0].Blockable||devices[1].Blockable||devices[2].Blockable{t.Fatalf("unexpected devices: %+v",devices)}
    cfg:=Config{InternalID:devices[0].ID}
    rule,err:=b.RequestPermission(cfg,false)
    if err!=nil||!strings.Contains(rule,`ENV{ID_PATH}=="platform-i8042-serio-0"`)||!strings.Contains(rule,`TAG+="uaccess"`){t.Fatalf("permission rule: %s %v",rule,err)}
    if err=b.Grab(devices[0]);err==nil{t.Fatal("ordinary file passed evdev identity check")}
    if _,err=b.RequestPermission(Config{InternalID:"missing"},false);err==nil{t.Fatal("permission granted to unknown device")}
}
