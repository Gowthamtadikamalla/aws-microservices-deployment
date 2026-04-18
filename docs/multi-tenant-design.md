# Multi-Tenant Design

This project is not a fully multi-tenant SaaS platform today. It is a small
stack of stateless services. This document explains where tenancy hooks live
in the current code and how the design would evolve if tenancy becomes a
first-class concern.

## Tenancy hooks in this stack

1. **Tenant context on every request**
   - `servers/service1/service1.py` and `servers/service2/service2.py` read
     `X-Tenant-ID` (and `X-Request-ID`) from the incoming request in a
     Flask `@before_request` hook.
   - Missing headers default to `tenant_id = "unknown"` so single-tenant
     callers are not rejected.
   - The header is echoed back in the JSON response for client-side
     correlation and attached to every access log line.

2. **Tenant-aware logs**
   - Access log lines are structured JSON and always include `tenant_id`,
     `request_id`, `service`, `environment`, `path`, `method`, and `status`.
   - Log group `/<project>/<env>/services` is queryable with CloudWatch
     Logs Insights, e.g.:

     ```
     fields @timestamp, tenant_id, path, status
     | filter status >= 500
     | stats count() by tenant_id
     ```

3. **Tenant-agnostic infrastructure**
   - A single ALB, ASG, ECR repo, and log group serve every tenant. Isolation
     today is purely at the application log/metric level, not at the network
     or data layer.

## Isolation models considered

| Model | Description | Where this stack sits | When to move to it |
|-------|-------------|-----------------------|--------------------|
| Logical | One stack, tenant id in headers/logs. | **Current model.** | Small customer count, no strict compliance. |
| Per-tenant database / row-level security | Shared compute, scoped data access. | Not in scope (no datastore yet). | First customer asks for data separation guarantees. |
| Per-tenant compute pool | Separate ASG/container set per tenant tier. | Not in scope. | Noisy-neighbour problems or per-tenant SLAs. |
| Per-tenant account | Separate AWS account per tenant. | Not in scope. | Enterprise deals requiring blast-radius isolation. |

## Evolution path

When tenancy becomes material, the cheapest upgrades to make first are:

1. **Trust the header only from the gateway.** Today any client can set
   `X-Tenant-ID`. As soon as authentication is introduced, the gateway
   (API Gateway, ALB + Cognito, or an auth proxy) must set the header from
   the verified claim and strip any client-supplied value.
2. **Attach tenant id to metrics.** Prometheus `Counter.labels(tenant=...)`
   for request counts and error counts; cardinality budget: dozens to low
   hundreds of tenants, not millions.
3. **Per-tenant rate limiting.** Upgrade the WAF rule from per-IP to
   per-tenant once the header is trusted, or introduce a dedicated rate
   limiter.
4. **Tenant-scoped IAM.** If services start writing to per-tenant S3
   prefixes or DynamoDB items, switch from a single EC2 role to scoped
   session credentials (STS `AssumeRoleWithSessionTags`).
5. **Tenant-specific encryption keys.** For regulated customers, KMS CMKs
   per tenant so key access can be audited and revoked independently.

## What this design avoids

- **Hard-coding tenant ids anywhere in Terraform.** Tenants are not
  infrastructure-shaped objects in this stack. Keeping them in the application
  request context means onboarding a tenant is a data operation, not a deploy.
- **Overbuilding for scale not yet observed.** Per-tenant stacks are
  expensive to run and to reason about; they are justified by specific
  customer or compliance requirements, not by "SaaS best practice".
