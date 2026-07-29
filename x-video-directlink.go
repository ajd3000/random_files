package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
)

type FXResponse struct {
	Code  int `json:"code"`
	Tweet struct {
		Author struct {
			Name       string `json:"name"`
			ScreenName string `json:"screen_name"`
		} `json:"author"`
		Text  string `json:"text"`
		Media struct {
			Videos []struct {
				Variants []struct {
					URL     string `json:"url"`
					Bitrate int    `json:"bitrate"`
				} `json:"variants"`
				Formats []struct {
					URL     string `json:"url"`
					Bitrate int    `json:"bitrate"`
				} `json:"formats"`
			} `json:"videos"`
		} `json:"media"`
	} `json:"tweet"`
}

type VideoLink struct {
	Resolution string
	Bitrate    int
	URL        string
}

func extractStatusID(input string) string {
	re := regexp.MustCompile(`status/(\d+)`)
	matches := re.FindStringSubmatch(input)
	if len(matches) > 1 {
		return matches[1]
	}
	// Check if raw ID
	reDigits := regexp.MustCompile(`^\d+$`)
	if reDigits.MatchString(input) {
		return input
	}
	return ""
}

func printHelp() {
	fmt.Println("X Video Direct Link Extractor")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  go run x-video-directlink.go <url-or-status-id>")
	fmt.Println()
	fmt.Println("Arguments:")
	fmt.Println("  <url-or-status-id>   Full X/Twitter post URL or numeric status ID")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  go run x-video-directlink.go https://x.com/user/status/1234567890")
	fmt.Println("  go run x-video-directlink.go 1234567890")
}

func main() {
	if len(os.Args) < 2 || os.Args[1] == "-h" || os.Args[1] == "--help" {
		printHelp()
		os.Exit(0)
	}

	target := os.Args[1]

	statusID := extractStatusID(target)
	if statusID == "" {
		fmt.Println("Error: Invalid X/Twitter URL or status ID")
		fmt.Println()
		printHelp()
		os.Exit(1)
	}

	apiURL := fmt.Sprintf("https://api.fxtwitter.com/status/%s", statusID)
	req, err := http.NewRequest("GET", apiURL, nil)
	if err != nil {
		fmt.Printf("Error creating request: %v\n", err)
		os.Exit(1)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("Error fetching data: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Printf("Error reading response: %v\n", err)
		os.Exit(1)
	}

	var fxData FXResponse
	if err := json.Unmarshal(body, &fxData); err != nil {
		fmt.Printf("Error parsing JSON: %v\n", err)
		os.Exit(1)
	}

	resRegex := regexp.MustCompile(`/(\d+x\d+)/`)
	var links []VideoLink
	seen := make(map[string]bool)

	for _, vid := range fxData.Tweet.Media.Videos {
		allVars := append(vid.Variants, vid.Formats...)
		for _, v := range allVars {
			if strings.Contains(v.URL, "video.twimg.com") && strings.Contains(v.URL, ".mp4") && !seen[v.URL] {
				seen[v.URL] = true
				res := "Unknown"
				sub := resRegex.FindStringSubmatch(v.URL)
				if len(sub) > 1 {
					res = sub[1]
				} else {
					res = fmt.Sprintf("%d bps", v.Bitrate)
				}
				links = append(links, VideoLink{
					Resolution: res,
					Bitrate:    v.Bitrate,
					URL:        v.URL,
				})
			}
		}
	}

	if len(links) == 0 {
		fmt.Println("No MP4 video links found for this tweet.")
		return
	}

	sort.Slice(links, func(i, j int) bool {
		return links[i].Bitrate > links[j].Bitrate
	})

	fmt.Println("=== X Video Direct Download Link Extractor ===")
	fmt.Printf("Author: %s (@%s)\n", fxData.Tweet.Author.Name, fxData.Tweet.Author.ScreenName)
	fmt.Printf("Tweet: %s\n\n", fxData.Tweet.Text)
	fmt.Println("Direct twimg URLs:")
	for i, l := range links {
		fmt.Printf("[%d] Quality (%s): %s\n", i+1, l.Resolution, l.URL)
	}

	fmt.Printf("\nTop Quality Direct Download Link:\n%s\n", links[0].URL)
}
