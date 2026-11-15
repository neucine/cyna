package svd

import (
	"bytes"
	"strings"
	"testing"
)

func TestGenerateCynaHandlesDerivesArraysClustersAccessAndEnums(t *testing.T) {
	var out bytes.Buffer
	if err := Convert(strings.NewReader(testSVD), &out, Options{}); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	for _, needle := range []string{
		"pub const vendor: string = \"Acme\";",
		"pub const width: u32 = 32;",
		"pub struct gpio0",
		"pub enum Bits: u4",
		"reserved_0 = 0,",
		"pin0 = 1,",
		"reserved_3 = 3,",
		"pub packed struct Outen",
		"pub bits: gpio0.Outen.Bits;",
		"/// SVD writeConstraint: range 0..255",
		"/// SVD resetValue: 0x0",
		"pub const outen: mmio.Reg32<gpio0.Outen> = { addr: 0x1000 };",
		"/// SVD access: read-only",
		"pub const input: mmio.Reg32RO<gpio0.Input> = { addr: 0x1004 };",
		"pub packed struct Out",
		"/// SVD readAction: clear",
		"pub raw: u32;",
		"pub const out0: mmio.Reg32<gpio0.Out> = { addr: 0x1010 };",
		"pub const out: [2]mmio.Reg32<gpio0.Out> = [2]mmio.Reg32<gpio0.Out> [",
		"gpio0.out0,",
		"gpio0.out1,",
		"pub const bank_cfg: mmio.Reg32<gpio0.BankCfg> = { addr: 0x1020 };",
		"res0: u4;",
		"pub struct gpio1",
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("generated output missing %q\n%s", needle, text)
		}
	}
}

func TestParseEnumValueAllowsHexAndRejectsWildcards(t *testing.T) {
	if value, ok := parseEnumValue("0x4"); !ok || value != 4 {
		t.Fatalf("expected 0x4 to parse as 4, got value=%d ok=%v", value, ok)
	}
	if value, ok := parseEnumValue("1 << 3"); !ok || value != 8 {
		t.Fatalf("expected shift expression to parse as 8, got value=%d ok=%v", value, ok)
	}
	if _, ok := parseEnumValue("#1x0"); ok {
		t.Fatal("expected wildcard enum value to be rejected")
	}
}

func TestGenerateCynaDropsOverlappingFields(t *testing.T) {
	var out bytes.Buffer
	if err := Convert(strings.NewReader(overlapSVD), &out, Options{}); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	for _, needle := range []string{
		"pub res0: u1;",
		"pub b: u2;",
		"pub c: u1;",
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("generated output missing %q\n%s", needle, text)
		}
	}
	for _, needle := range []string{
		"pub a0:",
		"pub a1:",
	} {
		if strings.Contains(text, needle) {
			t.Fatalf("generated output should drop overlapping field %q\n%s", needle, text)
		}
	}
}

const testSVD = `
<device>
  <vendor>Acme</vendor>
  <name>DemoSoc</name>
  <width>32</width>
  <peripherals>
    <peripheral>
      <name>GPIO0</name>
      <baseAddress>0x1000</baseAddress>
      <registers>
        <register>
          <name>OUTEN</name>
          <addressOffset>0x0</addressOffset>
          <size>32</size>
          <resetValue>0x0</resetValue>
          <writeConstraint>
            <range>
              <minimum>0</minimum>
              <maximum>255</maximum>
            </range>
          </writeConstraint>
          <fields>
            <field>
              <name>BITS</name>
              <bitOffset>0</bitOffset>
              <bitWidth>4</bitWidth>
              <enumeratedValues>
                <enumeratedValue><name>PIN0</name><value>1</value></enumeratedValue>
                <enumeratedValue><name>PIN1</name><value>2</value></enumeratedValue>
                <enumeratedValue><name>PIN2</name><value>4</value></enumeratedValue>
              </enumeratedValues>
            </field>
            <field derivedFrom="BITS">
              <name>OTHER</name>
              <bitOffset>8</bitOffset>
            </field>
          </fields>
        </register>
        <register derivedFrom="OUTEN">
          <name>INPUT</name>
          <addressOffset>0x4</addressOffset>
          <access>read-only</access>
        </register>
        <register>
          <dim>2</dim>
          <dimIncrement>4</dimIncrement>
          <name>OUT%s</name>
          <addressOffset>0x10</addressOffset>
          <size>32</size>
          <fields>
            <field><name>RAW</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth><readAction>clear</readAction></field>
          </fields>
        </register>
        <cluster>
          <dim>1</dim>
          <name>BANK%s</name>
          <addressOffset>0x20</addressOffset>
          <register>
            <name>CFG</name>
            <addressOffset>0x0</addressOffset>
            <fields>
              <field><name>ENABLE</name><lsb>0</lsb><msb>0</msb></field>
            </fields>
          </register>
        </cluster>
      </registers>
    </peripheral>
    <peripheral derivedFrom="GPIO0">
      <name>GPIO1</name>
      <baseAddress>0x2000</baseAddress>
    </peripheral>
  </peripherals>
</device>`

const overlapSVD = `
<device>
  <vendor>Acme</vendor>
  <name>OverlapSoc</name>
  <width>32</width>
  <peripherals>
    <peripheral>
      <name>REGS</name>
      <baseAddress>0x1000</baseAddress>
      <registers>
        <register>
          <name>BAD</name>
          <addressOffset>0x0</addressOffset>
          <size>4</size>
          <fields>
            <field><name>A0</name><lsb>0</lsb><msb>0</msb></field>
            <field><name>A1</name><lsb>0</lsb><msb>0</msb></field>
            <field><name>B</name><lsb>1</lsb><msb>2</msb></field>
            <field><name>C</name><lsb>3</lsb><msb>3</msb></field>
          </fields>
        </register>
      </registers>
    </peripheral>
  </peripherals>
</device>`
