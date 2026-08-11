# Tenancy

Status: draft
Scope: `0xda-market/core` plus external channel adapters
Change type: architecture proposal, no implementation

## Problem

The core is a single-operator marketplace. Every product, price, order and role
belongs to one implicit owner. Serving a second shop today requires a second
deployment, a second database and separate adapter runtime configuration.

Tenancy is the change that turns the engine into something that can be sold to the
operators who already have supply and demand.

## Principle

Tenancy is a persistence and authorization concern. It is not a domain concern.

`Core::Kernel` must not learn the word "tenant". Intent, quote and order lifecycle
rules are identical for every tenant. The scope is resolved once at the transport
boundary and carried inward as an explicit argument.

No ambient state. No thread-locals, no `Current.tenant`, no implicit default. A
store method that can be called without a tenant scope is a defect, and the
existing architecture-boundary tests are the right place to enforce that.

## Identity model

The decision that shapes everything else: **users stay global, roles become
tenant-scoped.**

```
market.users                stable internal UUID, one human, platform-wide
market.user_identities      unchanged
market.tenants              id, slug, status, created_at
market.tenant_memberships   tenant_id, user_id, role, status
```

Rationale: an external provider user ID may be globally unique within its provider.
Duplicating a user per tenant would break the single-internal-UUID invariant that
authentication, authorization, pricing provenance and broker ownership all rest on.
Membership is the correct place for multiplicity.

`client`, `broker` and `admin` become tenant-scoped roles. A new platform-level
role sits above them and is held only by the platform operator. Tenant admins must
not be able to reach platform operations, and the check belongs in the core, not in
a channel adapter.

## What is scoped and what is not

Tenant-scoped:

- `market.products` activation, position, status
- `market.product_localizations`
- `market.product_prices`
- `market.intents`, `market.quotes`, `market.orders`
- broker listings
- operator tasks

Platform-scoped, deliberately shared:

- FX snapshots. An exchange rate is a fact about the world, not about a shop.
  Duplicating the refresh process per tenant multiplies cost and creates
  inconsistent pricing for no benefit.
- The canonical SKU registry. A canonical product SKU is the same object
  everywhere. Tenants activate, localize, position and price it; they do not
  re-enter it.

The second point is strategic, not just tidy. A shared SKU registry is the
precondition for broker liquidity crossing tenant boundaries later. Tenant-local
SKUs would foreclose that permanently.

## Enforcement

Scope resolution:

```
request
  -> per-tenant API credential
  -> TenantScope value object (tenant_id, resolved once, immutable)
  -> application service (explicit argument)
  -> store port (required argument)
```

Credentials move from environment variables to hashed per-tenant records.
`PUBLIC_API_TOKEN` and `MANUAL_PROVIDER_TOKEN` are retained as platform bootstrap
credentials only.

Architecture tests extend to assert that no persistence adapter issues a query
against a scoped table without a tenant predicate.

## Channel adapter contract

A shared adapter process may serve many tenant-specific channel identities. The
core contract does not prescribe one concrete channel protocol.

- an adapter route carries or resolves the tenant before core authentication;
- channel credentials are resolved per tenant outside core;
- host-specific signature validation happens before the request reaches core;
- the anti-corruption layer is unchanged; it gains an explicit tenant argument on the way in.

Channel credentials are tenant secrets. They must live in the adapter's secure
runtime configuration or encrypted credential store, never in core domain state.

## Migration

Per the repository migration rules, verified against the test Supabase project
first:

1. create `market.tenants`, insert the existing operator as tenant one;
2. create `market.tenant_memberships`, backfill from current `market.users` roles;
3. add nullable `tenant_id` to scoped tables;
4. backfill to tenant one;
5. set `NOT NULL`, add composite indexes leading with `tenant_id`;
6. drop the legacy global-role read path.

Steps 1 to 4 are reversible. Step 5 is the commitment point.

## Non-goals

Billing and subscription management, per-tenant custom domains, per-tenant
deployment isolation, tenant-level data export, cross-tenant broker routing. The
last is enabled by this design but is a separate change.

## Open questions

- Does a broker belong to one tenant or to the platform? Platform-level brokers are
  the more valuable answer and the harder one; tenant-level is shippable now and
  does not block the other later.
- Where does the platform's own shop live: as tenant one, or outside the tenant
  model entirely? Tenant one is simpler and keeps one code path exercised.
- Per-tenant margin configuration: tenant-owned, platform-capped, or both?
