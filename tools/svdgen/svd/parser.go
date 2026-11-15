package svd

import (
	"encoding/xml"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"cyna.dev/tools/svdgen/svd/schema"
)

func Parse(svd []byte) Device {

	var dev schema.Device
	err := xml.Unmarshal(svd, &dev)
	if err != nil {
		panic(err)
	}

	device := mapDevice(dev)
	derive(device)

	return device
}

func mapDevice(dev schema.Device) Device {

	length := 0
	if dev.Peripherals != nil {
		length = len(dev.Peripherals.Peripheral)
	}

	peripherals := make([]Peripheral, length)
	for i := 0; i < len(peripherals); i++ {
		p := dev.Peripherals.Peripheral[i]

		peripherals[i] = mapPeripheral(p)
	}
	return Device{
		Vendor:      dev.Vendor,
		Name:        dev.Name,
		Series:      dev.Series,
		Description: dev.Description,
		LicenseText: dev.LicenseText,
		Width:       dev.Width,
		Peripherals: peripherals,
	}
}

func mapPeripheral(p *schema.PeripheralType) Peripheral {
	registerLength := 0
	clusterLength := 0
	if p.Registers != nil {
		registerLength = len(p.Registers.Register)
		clusterLength = len(p.Registers.Cluster)
	}

	registers := make([]Register, registerLength)
	for j := 0; j < len(registers); j++ {
		r := p.Registers.Register[j]

		registers[j] = mapRegister(r)
	}

	clusters := make([]Cluster, clusterLength)
	for j := 0; j < len(clusters); j++ {
		c := p.Registers.Cluster[j]

		clusters[j] = mapCluster(c)
	}

	return Peripheral{
		DerivedFrom: p.DerivedFromAttr,
		Name:        p.Name,
		Version:     p.Version,
		Description: p.Description,
		BaseAddress: p.BaseAddress,
		Access:      inheritedAccess("", p.RegisterPropertiesGroup),
		Registers:   registers,
		Clusters:    clusters,
	}
}

func mapRegister(r *schema.RegisterType) Register {
	length := 0
	if r.Fields != nil {
		length = len(r.Fields.Field)
	}

	fields := make([]Field, length)
	for k := 0; k < len(fields); k++ {
		f := r.Fields.Field[k]

		fields[k] = mapField(f)
	}

	return Register{
		DerivedFrom:         r.DerivedFromAttr,
		Dim:                 r.Dim,
		DimIncrement:        r.DimIncrement,
		Name:                validName(r.Name),
		DisplayName:         r.DisplayName,
		Description:         r.Description,
		AddressOffset:       r.AddressOffset,
		Size:                r.Size,
		Access:              r.Access,
		DataType:            r.DataType,
		ModifiedWriteValues: r.ModifiedWriteValues,
		WriteConstraint:     formatWriteConstraint(r.WriteConstraint),
		ReadAction:          r.ReadAction,
		ResetValue:          r.ResetValue,
		ResetMask:           r.ResetMask,
		Fields:              fields,
	}
}

func mapCluster(c *schema.ClusterType) Cluster {
	length := 0
	if c.Register != nil {
		length = len(c.Register)
	}

	registers := make([]Register, length)
	for k := 0; k < len(registers); k++ {
		r := c.Register[k]

		registers[k] = mapRegister(r)
	}

	return Cluster{
		DerivedFrom:   c.DerivedFromAttr,
		Name:          c.Name,
		Dim:           c.Dim,
		DimIncrement:  c.DimIncrement,
		Description:   c.Description,
		AddressOffset: c.AddressOffset,
		Registers:     registers,
	}
}

func mapField(f *schema.FieldType) Field {
	length := 0
	if f.EnumeratedValues != nil && len(f.EnumeratedValues) > 0 {
		length = len(f.EnumeratedValues[0].EnumeratedValue)
	}

	enums := make([]EnumeratedValue, length)
	for l := 0; l < len(enums); l++ {
		e := f.EnumeratedValues[0].EnumeratedValue[l]
		enum := EnumeratedValue{
			Name:        validName(e.Name),
			Description: e.Description,
			Value:       e.Value,
			IsDefault:   e.IsDefault,
		}
		enums[l] = enum
	}
	return Field{
		DerivedFrom:         f.DerivedFromAttr,
		Dim:                 f.Dim,
		DimIncrement:        f.DimIncrement,
		Name:                validName(f.Name),
		Description:         f.Description,
		Access:              f.Access,
		ModifiedWriteValues: f.ModifiedWriteValues,
		WriteConstraint:     formatWriteConstraint(f.WriteConstraint),
		ReadAction:          f.ReadAction,
		Lsb:                 f.Lsb,
		Msb:                 f.Msb,
		BitOffset:           f.BitOffset,
		BitWidth:            f.BitWidth,
		BitRange:            f.BitRange,
		EnumeratedValues:    enums,
	}
}

func formatWriteConstraint(c *schema.WriteConstraintType) string {
	if c == nil {
		return ""
	}
	parts := make([]string, 0, 3)
	if c.WriteAsRead {
		parts = append(parts, "writeAsRead")
	}
	if c.UseEnumeratedValues {
		parts = append(parts, "useEnumeratedValues")
	}
	if c.Range != nil {
		parts = append(parts, fmt.Sprintf("range %s..%s", c.Range.Minimum, c.Range.Maximum))
	}
	return strings.Join(parts, ", ")
}

func validName(name string) string {
	if name[0] >= '0' && name[0] <= '9' {
		return "@\"" + name + "\""
	}
	return name
}

func toNumber(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if strings.HasPrefix(s, "0x") {
		n, err := strconv.ParseInt(s[2:], 16, 64)
		if err != nil {
			warn("unable to covert hex %s", s)
		}
		return int(n)
	}
	if strings.HasPrefix(s, "0b") {
		n, err := strconv.ParseInt(s[2:], 2, 64)
		if err != nil {
			warn("unable to covert binary %s", s)
		}
		return int(n)
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		warn("unable to covert number %s", s)
	}
	return n
}

func info(message string, args ...any) {
	fmt.Printf("[info]"+message, args...)
}

func warn(message string, args ...any) {
	text := fmt.Sprintf(message, args...)
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	fmt.Fprintf(os.Stderr, "svdgen: warning: %s", text)
}

func fatal(message string, args ...any) {
	panic(fmt.Sprintf("[fatal]"+message, args...))
}

func assert(exp bool, message string, args ...any) {
	if !exp {
		panic(fmt.Sprintf("assert fails: "+message, args...))
	}
}

func derive(device Device) {
	resolvePeripheralDerives(&device)
	for i := 0; i < len(device.Peripherals); i++ {
		p := &device.Peripherals[i]

		resolveRegisterDerives(p)
		resolveClusterDerives(p)
		for j := 0; j < len(p.Registers); j++ {
			resolveFieldDerives(&p.Registers[j])
		}
		for j := 0; j < len(p.Clusters); j++ {
			for k := 0; k < len(p.Clusters[j].Registers); k++ {
				resolveFieldDerives(&p.Clusters[j].Registers[k])
			}
		}
		p.DerivedRegisters = markUniqueRegisterTypes(deriveRegisters(device, *p))
	}
}

func markUniqueRegisterTypes(registers []DerivedRegister) []DerivedRegister {
	seen := map[string]bool{}
	for i := range registers {
		if len(registers[i].Group) != 0 {
			registers[i].EmitType = false
			continue
		}
		if seen[registers[i].TypeName] {
			registers[i].EmitType = false
			continue
		}
		seen[registers[i].TypeName] = true
		registers[i].EmitType = true
	}
	return registers
}

func inheritedAccess(access string, group *schema.RegisterPropertiesGroup) string {
	if access != "" {
		return access
	}
	if group != nil {
		return group.Access
	}
	return ""
}

func resolvePeripheralDerives(device *Device) {
	for i := range device.Peripherals {
		p := &device.Peripherals[i]
		if p.DerivedFrom == "" {
			continue
		}
		if base := findPeripheral(device.Peripherals, p.DerivedFrom); base != nil {
			mergePeripheral(p, *base)
		}
	}
}

func findPeripheral(peripherals []Peripheral, name string) *Peripheral {
	for i := range peripherals {
		if peripherals[i].Name == name {
			return &peripherals[i]
		}
	}
	return nil
}

func mergePeripheral(dst *Peripheral, src Peripheral) {
	if dst.Version == "" {
		dst.Version = src.Version
	}
	if dst.Description == "" {
		dst.Description = src.Description
	}
	if dst.Access == "" {
		dst.Access = src.Access
	}
	if len(dst.Registers) == 0 {
		dst.Registers = cloneRegisters(src.Registers)
	}
	if len(dst.Clusters) == 0 {
		dst.Clusters = cloneClusters(src.Clusters)
	}
}

func resolveRegisterDerives(p *Peripheral) {
	for i := range p.Registers {
		r := &p.Registers[i]
		if r.DerivedFrom == "" {
			continue
		}
		if base := findRegister(p.Registers, r.DerivedFrom); base != nil {
			mergeRegister(r, *base)
		}
	}
}

func findRegister(registers []Register, name string) *Register {
	for i := range registers {
		if registers[i].Name == name {
			return &registers[i]
		}
	}
	return nil
}

func mergeRegister(dst *Register, src Register) {
	if dst.Dim == "" {
		dst.Dim = src.Dim
	}
	if dst.DimIncrement == "" {
		dst.DimIncrement = src.DimIncrement
	}
	if dst.Description == "" {
		dst.Description = src.Description
	}
	if dst.AddressOffset == "" {
		dst.AddressOffset = src.AddressOffset
	}
	if dst.Size == "" {
		dst.Size = src.Size
	}
	if dst.Access == "" {
		dst.Access = src.Access
	}
	if dst.DataType == "" {
		dst.DataType = src.DataType
	}
	if dst.ModifiedWriteValues == "" {
		dst.ModifiedWriteValues = src.ModifiedWriteValues
	}
	if dst.WriteConstraint == "" {
		dst.WriteConstraint = src.WriteConstraint
	}
	if dst.ReadAction == "" {
		dst.ReadAction = src.ReadAction
	}
	if dst.ResetValue == "" {
		dst.ResetValue = src.ResetValue
	}
	if dst.ResetMask == "" {
		dst.ResetMask = src.ResetMask
	}
	if len(dst.Fields) == 0 {
		dst.Fields = cloneFields(src.Fields)
	}
}

func resolveClusterDerives(p *Peripheral) {
	for i := range p.Clusters {
		c := &p.Clusters[i]
		if c.DerivedFrom == "" {
			continue
		}
		if base := findCluster(p.Clusters, c.DerivedFrom); base != nil {
			mergeCluster(c, *base)
		}
	}
}

func findCluster(clusters []Cluster, name string) *Cluster {
	for i := range clusters {
		if clusters[i].Name == name {
			return &clusters[i]
		}
	}
	return nil
}

func mergeCluster(dst *Cluster, src Cluster) {
	if dst.Dim == "" {
		dst.Dim = src.Dim
	}
	if dst.DimIncrement == "" {
		dst.DimIncrement = src.DimIncrement
	}
	if dst.Description == "" {
		dst.Description = src.Description
	}
	if dst.AddressOffset == "" {
		dst.AddressOffset = src.AddressOffset
	}
	if len(dst.Registers) == 0 {
		dst.Registers = cloneRegisters(src.Registers)
	}
}

func resolveFieldDerives(r *Register) {
	for i := range r.Fields {
		f := &r.Fields[i]
		if f.DerivedFrom != "" {
			if base := findField(r.Fields, f.DerivedFrom); base != nil {
				mergeField(f, *base)
			}
		}
		resolveEnumDerives(r.Fields, f)
	}
}

func findField(fields []Field, name string) *Field {
	for i := range fields {
		if fields[i].Name == name {
			return &fields[i]
		}
	}
	return nil
}

func mergeField(dst *Field, src Field) {
	if dst.Dim == "" {
		dst.Dim = src.Dim
	}
	if dst.DimIncrement == "" {
		dst.DimIncrement = src.DimIncrement
	}
	if dst.Description == "" {
		dst.Description = src.Description
	}
	if dst.BitRange == "" {
		dst.BitRange = src.BitRange
	}
	if dst.Lsb == "" {
		dst.Lsb = src.Lsb
	}
	if dst.Msb == "" {
		dst.Msb = src.Msb
	}
	if dst.BitOffset == "" {
		dst.BitOffset = src.BitOffset
	}
	if dst.BitWidth == "" {
		dst.BitWidth = src.BitWidth
	}
	if dst.Access == "" {
		dst.Access = src.Access
	}
	if dst.ModifiedWriteValues == "" {
		dst.ModifiedWriteValues = src.ModifiedWriteValues
	}
	if dst.WriteConstraint == "" {
		dst.WriteConstraint = src.WriteConstraint
	}
	if dst.ReadAction == "" {
		dst.ReadAction = src.ReadAction
	}
	if len(dst.EnumeratedValues) == 0 {
		dst.EnumeratedValues = append([]EnumeratedValue(nil), src.EnumeratedValues...)
	}
}

func resolveEnumDerives(fields []Field, f *Field) {
	if len(f.EnumeratedValues) != 0 || len(fields) == 0 {
		return
	}
	for _, base := range fields {
		if len(base.EnumeratedValues) != 0 && base.Name == f.DerivedFrom {
			f.EnumeratedValues = append([]EnumeratedValue(nil), base.EnumeratedValues...)
			return
		}
	}
}

func cloneRegisters(registers []Register) []Register {
	out := append([]Register(nil), registers...)
	for i := range out {
		out[i].Fields = cloneFields(out[i].Fields)
	}
	return out
}

func cloneClusters(clusters []Cluster) []Cluster {
	out := append([]Cluster(nil), clusters...)
	for i := range out {
		out[i].Registers = cloneRegisters(out[i].Registers)
	}
	return out
}

func cloneFields(fields []Field) []Field {
	out := append([]Field(nil), fields...)
	for i := range out {
		out[i].EnumeratedValues = append([]EnumeratedValue(nil), out[i].EnumeratedValues...)
	}
	return out
}

func replace(s string, to string, from ...string) string {
	var str = s
	for i := 0; i < len(from); i++ {
		str = strings.ReplaceAll(str, from[i], to)
	}
	return str
}

func deriveRegisters(device Device, p Peripheral) []DerivedRegister {
	size := toNumber(device.Width)
	baseAddress := toNumber(p.BaseAddress)

	registers := make([]DerivedRegister, 0)
	for j := 0; j < len(p.Registers); j++ {
		r := p.Registers[j]

		name := r.Name
		typeName := baseTypeName(r.Name)
		description := r.Description
		addressOffset := toNumber(r.AddressOffset)
		access := accessOrDefault(r.Access, p.Access)

		if r.Size != "" {
			size = toNumber(r.Size)
		}

		dim := 1
		if r.Dim != "" {
			dim = toNumber(r.Dim)
		}

		if dim == 1 {
			registers = append(registers, DerivedRegister{
				Name:                name,
				TypeName:            typeName,
				Description:         description,
				Address:             baseAddress + addressOffset,
				Size:                size,
				Access:              access,
				ModifiedWriteValues: r.ModifiedWriteValues,
				WriteConstraint:     r.WriteConstraint,
				ReadAction:          r.ReadAction,
				ResetValue:          r.ResetValue,
				ResetMask:           r.ResetMask,
				DerivedFields:       deriveFields(r, size),
				Group:               nil,
			})
		} else {
			names := make([]string, dim)
			dimIncrement := toNumber(r.DimIncrement)
			if dimIncrement == 0 {
				dimIncrement = size / 8
			}
			// add separate registers
			for k := 0; k < dim; k++ {
				name := replace(r.Name, strconv.Itoa(k), "[%s]", "%s")
				description = replace(r.Description, strconv.Itoa(k), "[%s]", "%s")
				names[k] = name
				registers = append(registers, DerivedRegister{
					Name:                name,
					TypeName:            typeName,
					Description:         description,
					Address:             baseAddress + addressOffset + k*dimIncrement,
					Size:                size,
					Access:              access,
					ModifiedWriteValues: r.ModifiedWriteValues,
					WriteConstraint:     r.WriteConstraint,
					ReadAction:          r.ReadAction,
					ResetValue:          r.ResetValue,
					ResetMask:           r.ResetMask,
					DerivedFields:       deriveFields(r, size),
					Group:               nil,
				})
			}
			// add a group register
			registers = append(registers, DerivedRegister{
				Name:                replace(r.Name, "", "[%s]", "%s"),
				TypeName:            typeName,
				Description:         replace(r.Description, "N", "[%s]", "%s"),
				Address:             baseAddress + addressOffset,
				Size:                size,
				Access:              access,
				ModifiedWriteValues: r.ModifiedWriteValues,
				WriteConstraint:     r.WriteConstraint,
				ReadAction:          r.ReadAction,
				ResetValue:          r.ResetValue,
				ResetMask:           r.ResetMask,
				DerivedFields:       deriveFields(r, size),
				Group:               names,
			})
		}

	}
	// FIXME, AVOID DUPLICATE
	for k := 0; k < len(p.Clusters); k++ {
		c := p.Clusters[k]
		clusterDim := 1
		if c.Dim != "" {
			clusterDim = toNumber(c.Dim)
		}
		clusterName := c.Name
		clusterAddressOffset := toNumber(c.AddressOffset)
		for kk := 0; kk < clusterDim; kk++ {
			if clusterDim > 1 {
				clusterName = replace(c.Name, strconv.Itoa(kk), "[%s]", "%s")
				clusterAddressOffset = toNumber(c.AddressOffset) + clusterDim*toNumber(c.DimIncrement)
			}

			for j := 0; j < len(c.Registers); j++ {
				r := c.Registers[j]

				name := r.Name
				typeName := baseTypeName(clusterName + "_" + r.Name)
				description := r.Description
				addressOffset := toNumber(r.AddressOffset)
				access := accessOrDefault(r.Access, p.Access)

				if r.Size != "" {
					size = toNumber(r.Size)
				}

				dim := 1
				if r.Dim != "" {
					dim = toNumber(r.Dim)
				}

				if dim == 1 {
					registers = append(registers, DerivedRegister{
						Name:                clusterName + "_" + name,
						TypeName:            typeName,
						Description:         description,
						Address:             baseAddress + clusterAddressOffset + addressOffset,
						Size:                size,
						Access:              access,
						ModifiedWriteValues: r.ModifiedWriteValues,
						WriteConstraint:     r.WriteConstraint,
						ReadAction:          r.ReadAction,
						ResetValue:          r.ResetValue,
						ResetMask:           r.ResetMask,
						DerivedFields:       deriveFields(r, size),
						Group:               nil,
					})
				} else {
					names := make([]string, dim)
					dimIncrement := toNumber(r.DimIncrement)
					if dimIncrement == 0 {
						dimIncrement = size / 8
					}
					// add separate registers
					for k := 0; k < dim; k++ {
						name := replace(r.Name, strconv.Itoa(k), "[%s]", "%s")
						description = replace(r.Description, strconv.Itoa(k), "[%s]", "%s")
						names[k] = clusterName + "_" + name
						registers = append(registers, DerivedRegister{
							Name:                clusterName + "_" + name,
							TypeName:            typeName,
							Description:         description,
							Address:             baseAddress + clusterAddressOffset + addressOffset + k*dimIncrement,
							Size:                size,
							Access:              access,
							ModifiedWriteValues: r.ModifiedWriteValues,
							WriteConstraint:     r.WriteConstraint,
							ReadAction:          r.ReadAction,
							ResetValue:          r.ResetValue,
							ResetMask:           r.ResetMask,
							DerivedFields:       deriveFields(r, size),
							Group:               nil,
						})
					}
					// add a group register
					registers = append(registers, DerivedRegister{
						Name:                clusterName + "_" + replace(r.Name, "", "[%s]", "%s"),
						TypeName:            typeName,
						Description:         replace(r.Description, "N", "[%s]", "%s"),
						Address:             baseAddress + clusterAddressOffset + addressOffset,
						Size:                size,
						Access:              access,
						ModifiedWriteValues: r.ModifiedWriteValues,
						WriteConstraint:     r.WriteConstraint,
						ReadAction:          r.ReadAction,
						ResetValue:          r.ResetValue,
						ResetMask:           r.ResetMask,
						DerivedFields:       deriveFields(r, size),
						Group:               names,
					})
				}
			}
		}

	}
	return registers
}

func accessOrDefault(access string, fallback string) string {
	if access != "" {
		return access
	}
	return fallback
}

func baseTypeName(name string) string {
	return replace(name, "", "[%s]", "%s", "%d")
}

func deriveFields(r Register, size int) []DerivedField {

	// normalise
	fields := make([]DerivedField, 0)
	for x := 0; x < len(r.Fields); x++ {
		f := r.Fields[x]
		var lsb int
		var msb int
		if f.Msb != "" && f.Lsb != "" {
			lsb = toNumber(f.Lsb)
			msb = toNumber(f.Msb)
		} else if f.BitOffset != "" && f.BitWidth != "" {
			lsb = toNumber(f.BitOffset)
			msb = toNumber(f.BitOffset) + toNumber(f.BitWidth) - 1
		} else if f.BitRange != "" {
			pair := strings.Split(f.BitRange[1:len(f.BitRange)-1], ":")
			sort.Slice(pair, func(i int, j int) bool { return pair[i] < pair[j] })
			lsb = toNumber(pair[0])
			msb = toNumber(pair[1])
		} else {
			fatal("Unable to find bit range %s.%s", r.Name, f.Name)
		}
		if lsb > msb {
			lsb, msb = msb, lsb
		}
		//assert(lsb <= msb, "%s.%s lsb (%d) is greater than msb (%d)", r.Name, f.Name, lsb, msb)
		assert(msb-lsb+1 > 0, "%s.%s size is 0 or negative", r.Name, f.Name, lsb, msb)

		dim := 1
		if f.Dim != "" {
			dim = toNumber(f.Dim)
		}
		name := f.Name
		description := f.Description
		size := msb - lsb + 1

		for k := 0; k < dim; k++ {
			if dim > 1 {
				name = replace(f.Name, strconv.Itoa(k), "[%s]", "%s")
				description = replace(f.Description, strconv.Itoa(k), "[%s]", "%s")
			}

			var defaultEnum = ""
			for _, enum := range f.EnumeratedValues {
				if enum.IsDefault {
					defaultEnum = enum.Name
					break
				}
			}

			fields = append(fields, DerivedField{
				Name:                name,
				TypeName:            baseTypeName(name),
				Description:         description,
				Access:              f.Access,
				ModifiedWriteValues: f.ModifiedWriteValues,
				WriteConstraint:     f.WriteConstraint,
				ReadAction:          f.ReadAction,
				Lsb:                 lsb + size*k,
				Msb:                 msb + size*k,
				Size:                size,
				Enums:               f.EnumeratedValues,
				DefaultEnum:         defaultEnum,
			})
		}
	}

	sort.SliceStable(fields, func(i, j int) bool {
		return fields[i].Lsb < fields[j].Lsb
	})
	fields = removeOverlappingFields(r, fields, size)

	// populate and add reserved fields
	derivedFields := make([]DerivedField, 0)
	res := 0
	if len(fields) == 0 {
		derivedFields = append(derivedFields, DerivedField{
			Name:  "raw",
			Lsb:   0,
			Msb:   size - 1,
			Size:  size,
			Enums: nil,
		})
	} else {
		offset := 0
		for x := 0; x < len(fields); x++ {
			f := fields[x]
			if f.Lsb > offset {
				derivedFields = append(derivedFields, DerivedField{
					Name:  fmt.Sprintf("res%d", res),
					Lsb:   offset,
					Msb:   f.Lsb - 1,
					Size:  f.Lsb - offset,
					Enums: nil,
				})
				res++
			}

			derivedFields = append(derivedFields, f)
			offset = f.Msb + 1
		}
		// check last remaining reserved
		if offset < size {
			derivedFields = append(derivedFields, DerivedField{
				Name:  fmt.Sprintf("res%d", res),
				Lsb:   offset,
				Msb:   size - 1,
				Size:  size - offset,
				Enums: nil,
			})
			res++
		}
	}

	return derivedFields
}

func removeOverlappingFields(r Register, fields []DerivedField, size int) []DerivedField {
	if len(fields) == 0 {
		return fields
	}
	bitOwner := make([]int, size)
	for i := range bitOwner {
		bitOwner[i] = -1
	}
	conflicts := make([]bool, len(fields))
	for i, field := range fields {
		if field.Lsb < 0 || field.Msb >= size {
			warn("dropping field %s.%s: bit range [%d:%d] is outside register width %d", r.Name, field.Name, field.Lsb, field.Msb, size)
			conflicts[i] = true
			continue
		}
		for bit := field.Lsb; bit <= field.Msb; bit++ {
			if bitOwner[bit] >= 0 {
				conflicts[i] = true
				conflicts[bitOwner[bit]] = true
				continue
			}
			bitOwner[bit] = i
		}
	}
	out := make([]DerivedField, 0, len(fields))
	for i, field := range fields {
		if conflicts[i] {
			warn("dropping field %s.%s: overlapping bit range [%d:%d]; generated output will use reserved bits for this range", r.Name, field.Name, field.Lsb, field.Msb)
			continue
		}
		out = append(out, field)
	}
	return out
}
