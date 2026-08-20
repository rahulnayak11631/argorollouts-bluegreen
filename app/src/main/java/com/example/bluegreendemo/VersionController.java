package com.example.bluegreendemo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.InetAddress;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Exposes /version so we can visually tell, from the outside, which
 * ReplicaSet (blue or green, old or new) is answering a given request.
 * APP_VERSION / APP_COLOR are plain env vars injected by the Rollout spec -
 * no rebuild needed to change them, but for this demo the pipeline bumps
 * APP_VERSION to the new git SHA on every release so /version proves the
 * preview pod is really running the freshly-built image before we promote it.
 */
@RestController
public class VersionController {

    @Value("${APP_VERSION:v1}")
    private String version;

    @Value("${APP_COLOR:blue}")
    private String color;

    @GetMapping("/")
    public String home() {
        return "Hello from Argo Rollouts Blue-Green demo - version=" + version + ", color=" + color;
    }

    @GetMapping("/version")
    public Map<String, String> versionInfo() throws Exception {
        Map<String, String> info = new LinkedHashMap<>();
        info.put("version", version);
        info.put("color", color);
        info.put("hostname", InetAddress.getLocalHost().getHostName());
        return info;
    }
}
