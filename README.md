# Oppulence shared workflows

Reusable GitHub Actions workflows for deploying Oppulence applications to DigitalOcean App Platform. The repository is public so public and private application repositories can call it. It contains no deployment credentials.

## App Platform deployment

[`digitalocean-app-platform.yml`](.github/workflows/digitalocean-app-platform.yml) is invoked with `workflow_call`. It checks that the run is on the authorized Git ref, validates the caller's complete App Platform spec, then updates an **existing** app with `doctl apps update --update-sources --wait`. It does not run on a push to this repository and does not create apps.

| Input or secret | Required | Purpose |
| --- | --- | --- |
| `app_id` | Yes | Existing DigitalOcean App Platform app ID |
| `app_spec_path` | Yes | Path to the full app spec in the caller repository |
| `deploy_ref` | Yes | Exact Git ref allowed to deploy, such as `refs/heads/main` |
| `environment` | Yes | GitHub environment for approval and branch protection |
| `digitalocean_token` | Yes | Caller secret with App Platform read and write access |

See [`examples/caller.yml`](examples/caller.yml) and [`examples/app.yaml`](examples/app.yaml) for a starting point. The example caller is pinned to the first reviewed workflow commit, `57990ac2693c8ce8554553947e35436a2ce96e4d`. Copy the caller into the **application** repository's `.github/workflows/` directory, and place its app spec there. Replace the example app ID variable, repository, spec path, and token secret. Add that app's required test, migration, and smoke jobs before enabling its production deployment. Its `github.branch` in the spec must match the branch in `deploy_ref`, and `deploy_on_push` must be `false` to avoid a second deployment outside CI.

### Provision each app once

1. Connect the app repository to DigitalOcean App Platform.
2. Prepare a **complete** spec. For an existing app, start with `doctl apps spec get <app-id>` so an update retains domains, components, and environment variables. Inspect secret fields and keep plaintext credentials out of Git.
3. For a new app, run `doctl apps create --spec .do/app.yaml --wait` from an authorized account. Save the resulting ID as a GitHub repository or organization variable, such as `DO_APP_ID`.
4. Store the DigitalOcean token as a secret in the **calling** repository or organization. Give staging and production separate credentials when those environments use separate DigitalOcean teams.
5. Create the named GitHub environment in the calling repository, restrict its deployment branches, and add required reviewers for production.
6. Ensure GitHub Actions is enabled in the calling repository and its organization policy permits public reusable workflows.

### Security and release policy

Pin callers to a reviewed **commit SHA** of this repository. A moving branch or tag could change the code that receives the caller's deployment token. Review workflow changes before updating caller pins. Never use `secrets: inherit`; pass only the named DigitalOcean token. Keep each application's runtime secrets in DigitalOcean or in a complete spec with DigitalOcean-encrypted values. The public workflow and its history must contain no tokens, private app specs, or customer data.

This source-based deployment asks App Platform to fetch the latest source on the branch in the spec. If that branch advances during a run, the deployed commit can differ from `github.sha`. Apps needing exact artifact promotion should build one image, push it to a registry, and deploy its immutable digest through an image-based spec.

## References

- [GitHub reusable workflow access](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)
- [GitHub secret passing and reuse syntax](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [DigitalOcean app spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/)
- [DigitalOcean `doctl apps update`](https://docs.digitalocean.com/reference/doctl/reference/apps/update/)
- [DigitalOcean `doctl apps spec get`](https://docs.digitalocean.com/reference/doctl/reference/apps/spec/get/)
