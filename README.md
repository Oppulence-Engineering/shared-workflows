# Oppulence shared workflows

Public, reusable GitHub Actions workflows for DigitalOcean App Platform. Public and private application repositories can call the workflow, subject to their GitHub Actions policy. This repository contains no deployment credentials or private app specs.

## Deploy an existing App Platform app

Copy [the caller example](examples/caller.yml) into each application's `.github/workflows/` directory and pin `uses:` to a reviewed commit SHA of this repository. The current `v1.1.0` release is `f7215a700a8ea15c7c1a378fa240ccdba1ac2098`. Copy [the example spec](examples/app.yaml) into the application repository, then replace its placeholders with that app's complete spec.

The workflow has two jobs:

1. **Validate** the caller ref, configuration, and full app spec without a DigitalOcean token.
2. **Deploy** after the GitHub environment gate. Revalidate, check the authorized branch head, inspect the target app, run DigitalOcean's spec validation, update the existing app, wait for completion, verify the active deployment, and optionally poll an HTTPS health endpoint.

The deployment job serializes updates to the same app ID within a caller repository. Assign each app ID to exactly one caller repository: GitHub concurrency does not coordinate across repositories, and simultaneous cross-repository updates can race. Failed deployments link to the app's DigitalOcean console. It does not automatically roll back: App Platform rollbacks do not reverse database changes.

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `app_id` | Required | Existing App Platform UUID. The app's current name must equal the spec name. |
| `app_spec_path` | Required | Complete spec path inside the calling repository. Paths that escape the checkout are rejected. |
| `deploy_ref` | Required | Exact `refs/heads/...` or `refs/tags/...` allowed to deploy. GitHub source components require a branch ref. |
| `environment` | Required | GitHub environment name. Configure its branch restrictions and approval rules in the caller. |
| `runner` | `ubuntu-latest` | Runner label used by both jobs; it must support the pinned actions, Ruby, Bash, Git, and doctl. |
| `doctl_version` | `1.180.0` | Exact doctl version in `major.minor.patch` form. |
| `timeout_minutes` | `60` | Deploy job timeout, 5–360 minutes. |
| `source_revision_policy` | `exact` | `exact`: require GitHub source from caller repo/branch and verify every deployed source commit equals `github.sha`. `branch`: require caller repo/branch but skip commit verification. `off`: allow other source providers and branches. |
| `require_image_digests` | `true` | Require image components to use an immutable `sha256:` digest and verify that the active deployment uses it. Set `false` to permit tags. |
| `healthcheck_url` | Empty | Optional HTTPS endpoint; success is any 2xx status. Redirects are not followed. |
| `healthcheck_attempts` | `12` | 1–100 attempts. |
| `healthcheck_interval_seconds` | `5` | 0–300 seconds between attempts. |
| `healthcheck_timeout_seconds` | `10` | 1–120 seconds per request. |

Secret: `digitalocean_token` is required. Pass it by name from the calling repository or organization. The token needs App Platform read and write access to the target app. Never use `secrets: inherit` for this call.

Outputs: `deployment_id` and `app_url` are available from the caller's deploy job. The job summary also links to the app.

### Source policies

`exact` is the recommended setting for GitHub source components. It requires every GitHub component to use the calling repository and branch, with `deploy_on_push: false`. The workflow checks that the remote branch still points to the caller's `github.sha` before updating, then compares App Platform's recorded commit hash after deployment. If the branch advances between those checks, the workflow fails, but App Platform might already have deployed that newer commit. For truly atomic promotion, build an image once, reference its digest in the spec, and keep `require_image_digests: true`.

`branch` accepts a changing branch head while still checking the repository and branch. `off` allows GitLab, Bitbucket, Git, and external GitHub sources. These modes cannot verify the deployed source revision against the caller commit. GitHub, GitLab, and Bitbucket sources require `deploy_on_push: false`; image sources must not enable `deploy_on_push`. This keeps deployments controlled by the workflow.

The workflow rejects plaintext `SECRET` environment values and plaintext image registry credentials in the committed spec. Use DigitalOcean encrypted `EV[...]` values or variable references. Keep all runtime secret values and credentials out of this public repository.

### Provision each app once

1. Connect the app repository to DigitalOcean. For an existing app, start with `doctl apps spec get <app-id>` and review the complete result before committing it. A partial spec can remove domains, components, environment variables, and other settings during update.
2. For a new app, create it once with `doctl apps create --spec .do/app.yaml --wait` using an authorized account. Save its ID as a GitHub variable such as `DO_APP_ID`.
3. Put the DigitalOcean token in the calling repository or organization as `DIGITALOCEAN_APP_PLATFORM_TOKEN`. Use separate tokens for separate DigitalOcean teams.
4. Create the caller's GitHub environment, restrict its deployment branches, and require reviewers for production if desired.
5. Add the application's own build, test, migration, and smoke jobs in the caller. Make the deployment job depend on those gates.
6. Enable GitHub Actions in the caller repository. Confirm organization policy permits a public reusable workflow and pinned third-party actions.

### Release and security policy

Pin callers to a reviewed **40-character commit SHA**. A moving branch or tag can change code that receives the deployment token. Version tags are protected against updates and deletion. Every update to this repository must pass `actionlint` and the validation tests before merge. Dependabot opens weekly pull requests for pinned GitHub Actions; review them and update each caller pin only after a new release. The pinned DigitalOcean, checkout, Ruby, and Go setup actions are also referenced by commit SHA.

The reusable workflow checks out its own scripts at the exact workflow revision using GitHub's `job.workflow_repository` and `job.workflow_sha` contexts. `actionlint` 1.7.12 predates these two documented contexts, so CI suppresses only those two false positives.

Run local checks with:

```bash
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 -ignore 'property "workflow_(repository|sha)" is not defined' .github/workflows/*.yml examples/caller.yml
ruby test/app_platform_test.rb
```

## References

- [GitHub reusable workflow access](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)
- [GitHub reusable workflow syntax](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [GitHub job context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)
- [DigitalOcean app spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/)
- [DigitalOcean doctl apps update](https://docs.digitalocean.com/reference/doctl/reference/apps/update/)
- [DigitalOcean deployment management](https://docs.digitalocean.com/products/app-platform/how-to/manage-deployments/)
