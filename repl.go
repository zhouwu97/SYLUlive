package main
import (
	"os"
	"strings"
)
func main() {
	code, _ := os.ReadFile("server/cmd/main.go")
	newJs, _ := os.ReadFile("scratch.go")
	
	codeStr := string(code)
	newJsStr := string(newJs)
	
	startIdx := strings.Index(codeStr, "jsCode := `(function() {")
	if startIdx == -1 {
		panic("not found start")
	}
	endIdx := strings.Index(codeStr[startIdx:], "})();`")
	if endIdx == -1 {
		panic("not found end")
	}
	endIdx += startIdx + 6
	
	finalCode := codeStr[:startIdx] + newJsStr + codeStr[endIdx:]
	os.WriteFile("server/cmd/main.go", []byte(finalCode), 0644)
}
