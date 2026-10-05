package main

import "testing"

func TestParseContainerRoutes(t *testing.T) {
	resp := []byte("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + `[
		{"Names":["/web"],"Labels":{},"Ports":[{"PrivatePort":80,"Type":"tcp"}],
		 "NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.2"}}}},
		{"Names":["/api"],"Labels":{"com.docker.compose.service":"api","com.docker.compose.project":"shop"},
		 "Ports":[{"PrivatePort":3000,"Type":"tcp"},{"PrivatePort":9229,"Type":"tcp"}],
		 "NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.3"}}}},
		{"Names":["/noip"],"Ports":[],"NetworkSettings":{"Networks":{}}}
	]`)

	routes := parseContainerRoutes(resp)

	web, ok := routes["web.sky.local"]
	if !ok || web.IP.String() != "172.17.0.2" || web.Port != 80 {
		t.Fatalf("web route = %+v, ok=%v", web, ok)
	}
	api, ok := routes["api.sky.local"]
	if !ok || api.IP.String() != "172.17.0.3" || api.Port != 3000 {
		t.Fatalf("api route = %+v (want 172.17.0.3:3000)", api)
	}
	if svc, ok := routes["api.shop.sky.local"]; !ok || svc.Port != 3000 {
		t.Fatalf("compose route = %+v, ok=%v", svc, ok)
	}
	if _, ok := routes["noip.sky.local"]; ok {
		t.Fatalf("container with no IP should be skipped")
	}
}

func TestPickHTTPPort(t *testing.T) {
	cases := []struct {
		in   []int
		want int
	}{
		{nil, 80},
		{[]int{80}, 80},
		{[]int{9229, 3000}, 3000}, // prefers 3000 over a random high port
		{[]int{8443, 8080}, 8080}, // prefers 8080
		{[]int{7000, 6000}, 6000}, // no preference → lowest
		{[]int{443, 80}, 80},      // prefers 80
	}
	for _, c := range cases {
		if got := pickHTTPPort(c.in); got != c.want {
			t.Errorf("pickHTTPPort(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}
