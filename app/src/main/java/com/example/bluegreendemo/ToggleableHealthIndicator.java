package com.example.bluegreendemo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

/**
 * Lets the "negative path" demo simulate a broken release without touching
 * code: set APP_HEALTHY=false (e.g. in an overlay patch) and /actuator/health
 * starts returning DOWN, which fails the Rollout's readinessProbe, which the
 * CI smoke test then catches -> pipeline aborts the dev Rollout automatically.
 */
@Component
public class ToggleableHealthIndicator implements HealthIndicator {

    @Value("${APP_HEALTHY:true}")
    private boolean healthy;

    @Override
    public Health health() {
        if (healthy) {
            return Health.up().build();
        }
        return Health.down().withDetail("reason", "APP_HEALTHY=false (simulated failure)").build();
    }
}
