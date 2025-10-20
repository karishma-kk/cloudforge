# ============================================
# Stage 1: Build (if needed for static assets)
# ============================================
FROM node:20-alpine AS builder

# Security: Run as non-root during build
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app
COPY website/ ./

# If you add a build step later (e.g. npm run build), do it here
# RUN npm ci --only=production && npm run build

# ============================================
# Stage 2: Production — Minimal Nginx Image
# ============================================
FROM nginx:1.27-alpine AS production

# Security: Remove default configs and server tokens
RUN rm -rf /usr/share/nginx/html/* \
    && rm /etc/nginx/conf.d/default.conf

# Custom nginx config with security headers
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf

# Copy website from builder
COPY --from=builder /app/ /usr/share/nginx/html/

# Security: Set proper file permissions
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chmod -R 555 /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown -R nginx:nginx /var/run/nginx.pid

# Security: Run as non-root user
USER nginx

# Expose port 80 (non-privileged)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
