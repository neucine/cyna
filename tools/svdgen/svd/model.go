package svd

type Device struct {
	Vendor      string
	Name        string
	Series      string
	Description string
	LicenseText string
	Width       string
	Peripherals []Peripheral
}

type Cpu struct {
	Name       string
	Revision   string
	Endian     string
	MpuPresent bool
	FpuPresent bool
}

type Peripheral struct {
	DerivedFrom string
	Name        string
	Version     string
	Description string
	BaseAddress string
	Access      string
	Registers   []Register
	Clusters    []Cluster
	// derived
	DerivedRegisters []DerivedRegister
}

type Register struct {
	DerivedFrom         string
	Dim                 string
	DimIncrement        string
	Name                string
	DisplayName         string
	Description         string
	AddressOffset       string
	Size                string
	Access              string
	DataType            string
	ModifiedWriteValues string
	WriteConstraint     string
	ReadAction          string
	ResetValue          string
	ResetMask           string
	Fields              []Field
}

type Cluster struct {
	DerivedFrom   string
	Name          string
	Dim           string
	DimIncrement  string
	Description   string
	AddressOffset string
	Registers     []Register
}

type DerivedRegister struct {
	// derived
	Name                string
	TypeName            string
	EmitType            bool
	Description         string
	Address             int
	Size                int
	Access              string
	ModifiedWriteValues string
	WriteConstraint     string
	ReadAction          string
	ResetValue          string
	ResetMask           string
	DerivedFields       []DerivedField
	Group               []string
}

type Field struct {
	DerivedFrom         string
	Dim                 string
	DimIncrement        string
	Name                string
	Description         string
	Access              string
	ModifiedWriteValues string
	WriteConstraint     string
	ReadAction          string
	// [1:2]
	BitRange string
	// lsb - msb
	Lsb string
	Msb string
	// 1..(2)
	BitOffset        string
	BitWidth         string
	EnumeratedValues []EnumeratedValue
}

type DerivedField struct {
	// derived
	Name                string
	TypeName            string
	Description         string
	Access              string
	ModifiedWriteValues string
	WriteConstraint     string
	ReadAction          string
	Lsb                 int
	Msb                 int
	Size                int
	Enums               []EnumeratedValue
	DefaultEnum         string
}

type EnumeratedValue struct {
	Name        string
	Description string
	Value       string
	IsDefault   bool
}
