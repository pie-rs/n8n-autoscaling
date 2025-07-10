# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |

## Security Features

### Built-in Security Measures

- **Cloudflare Tunnel Integration**: Zero open ports, automatic DDoS protection
- **Strong Password Generation**: Cryptographically secure passwords with salt
- **Network Isolation**: PostgreSQL defaults to localhost-only binding
- **Secure Defaults**: HTTPS cookies enabled, secure configuration templates
- **Input Validation**: Default password rejection, environment variable sanitization

### Security Architecture

```
Internet → Cloudflare → cloudflared → n8n (direct connection)
                                   ↓
                              PostgreSQL (localhost only)
                                   ↓
                               Redis (authenticated)
```

## Known Security Considerations

### Docker Socket Access (High Impact)

**Issue**: The autoscaler requires Docker socket access to manage containers.
**Impact**: Docker socket access provides root-level access to the host system.
**Mitigation**: 
- Only deploy on trusted networks
- Consider rootless Docker where possible
- For maximum security, use Kubernetes instead of Docker

### Secrets Management

**Current**: Environment variables in Docker Compose
**Security Level**: Medium (visible in process lists)
**Recommended**: Use Docker secrets or external secret management for production

### Backup Security

**Current**: Unencrypted backups with 7-day retention
**Recommendation**: Enable backup encryption for sensitive data

## Reporting a Vulnerability

If you discover a security vulnerability, please follow these steps:

1. **Do NOT** open a public issue
2. Contact the maintainers privately at [security contact]
3. Provide detailed information about the vulnerability
4. Allow reasonable time for the issue to be addressed

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested mitigation (if available)

## Security Updates

Security updates are released as needed and will be clearly marked in the changelog. Subscribe to repository notifications to stay informed about security updates.

## Compliance Notes

- **GDPR/CCPA**: Enable backup encryption for personal data processing
- **SOC 2**: Implement additional logging and access controls as needed
- **PCI DSS**: Not recommended for payment processing without additional hardening
- **HIPAA**: Additional encryption and audit controls required for healthcare data

## Security Hardening Recommendations

### For Production Deployments

1. **Network Security**
   - Use Cloudflare tunnels (recommended)
   - Configure firewall rules if using direct exposure
   - Enable Tailscale for team access

2. **Access Control**
   - Use strong, unique passwords (enforced by setup script)
   - Enable n8n user management
   - Regularly review access permissions

3. **Data Protection**
   - Enable backup encryption
   - Use HTTPS only (default with Cloudflare tunnels)
   - Protect log files from unauthorized access

4. **Monitoring**
   - Monitor container resource usage
   - Set up alerting for unusual activity
   - Regularly review access logs

### Docker Security Best Practices

- Use specific image tags instead of `latest`
- Regularly update base images
- Scan images for vulnerabilities
- Use non-root users where possible (implemented for n8n containers)

## Security Audit History

| Date | Scope | Findings | Status |
|------|-------|----------|--------|
| 2024-01 | Full repository audit | 17 issues identified | In Progress |

## Additional Resources

- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [Cloudflare Security Documentation](https://developers.cloudflare.com/fundamentals/security/)
- [n8n Security Guide](https://docs.n8n.io/hosting/security/)