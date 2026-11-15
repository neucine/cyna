package main

import (
	"flag"
	"fmt"
	"os"
	"path"
	"strings"

	"cyna.dev/tools/svdgen/svd"
)

func main() {
	var input string
	var output string
	var initialiseFields bool
	var emitFlags bool

	flag.StringVar(&input, "i", "", "input file *.svd")
	flag.StringVar(&output, "o", "", "output file")
	flag.String("soc", "", "ignored compatibility flag; Cyna output uses SVD device metadata")
	flag.BoolVar(&initialiseFields, "initialise-fields", true, "initialise fields")
	flag.BoolVar(&emitFlags, "emit-flags", false, "infer Cyna flags for enum values that look like bitsets")
	flag.Parse()

	if input == "" || output == "" {
		fmt.Printf("Usage: svd-gen -i <input_file> -o <output_file> -l <lang> \n")
		return
	}

	extension := strings.ToLower(path.Ext(output))
	if extension != ".cy" {
		fmt.Printf("Usage: svdgen -i <input_file> -o <output_file.cy>\n")
		return
	}

	// Open our file
	inputFile, err := os.Open(input)
	defer inputFile.Close()
	// if we os.Open returns an error then handle it
	if err != nil {
		fmt.Println(err)
		return
	}

	fmt.Printf("Succeeded to open %s\n", input)

	outputFile, err := os.OpenFile(output, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0644)
	defer outputFile.Close()

	if err != nil {
		fmt.Println(err)
		return
	}

	err = svd.Convert(inputFile, outputFile, svd.Options{
		InitialiseFields: initialiseFields,
		EmitFlags:        emitFlags,
	})

	if err != nil {
		fmt.Println(err)
		return
	}

	fmt.Printf("Succeeded to write %s\n", output)
}
