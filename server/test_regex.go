package main
import (
	"fmt"
	"regexp"
)
func main() {
	text := `[{"problem_id":"123","content":"<p><img src=\"https://foo.com/1.jpg\"></p>"}]`
	re := regexp.MustCompile(`<img[^>]+src=["'](https?://[^"']+)["']`)
	matches := re.FindAllStringSubmatch(text, -1)
	fmt.Printf("Matches: %v\n", matches)
    re2 := regexp.MustCompile(`<img[^>]+src=\\?["'](https?://[^"'\\]+)\\?["']`)
	matches2 := re2.FindAllStringSubmatch(text, -1)
	fmt.Printf("Matches2: %v\n", matches2)
}
