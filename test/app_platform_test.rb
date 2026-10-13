# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require_relative '../scripts/app_platform'

class AppPlatformTest < Minitest::Test
  APP_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  SHA = 'a' * 40

  def setup
    @dir = Dir.mktmpdir
    @old = ENV.to_h
    ENV.update(
      'APP_ID' => APP_ID,
      'APP_SPEC_PATH' => 'app.yaml',
      'DEPLOY_REF' => 'refs/heads/main',
      'DOCTL_VERSION' => '1.180.0',
      'DEPLOY_TIMEOUT_MINUTES' => '60',
      'SOURCE_REVISION_POLICY' => 'exact',
      'REQUIRE_IMAGE_DIGESTS' => 'true',
      'BUILD_IMAGE' => 'false',
      'IMAGE_REGISTRY_TYPE' => 'GHCR',
      'IMAGE_REGISTRY' => 'oppulence-engineering',
      'IMAGE_REPOSITORY' => 'demo',
      'DOCKERFILE_PATH' => 'Dockerfile',
      'BUILD_CONTEXT' => '.',
      'GITHUB_REPOSITORY' => 'Oppulence-Engineering/demo',
      'GITHUB_SHA' => SHA,
      'HEALTHCHECK_URL' => '',
      'HEALTHCHECK_ATTEMPTS' => '12',
      'HEALTHCHECK_INTERVAL_SECONDS' => '5',
      'HEALTHCHECK_TIMEOUT_SECONDS' => '10',
      'INFISICAL_IDENTITY_ID' => '',
      'INFISICAL_PROJECT_ID' => '',
      'INFISICAL_ENVIRONMENT' => 'prod',
      'INFISICAL_SECRET_PATH' => '/',
      'INFISICAL_DOMAIN' => 'https://app.infisical.com',
      'GITHUB_OUTPUT' => File.join(@dir, 'output'),
      'GITHUB_STEP_SUMMARY' => File.join(@dir, 'summary')
    )
    @spec = {
      'name' => 'demo-production',
      'services' => [{
        'name' => 'web',
        'github' => {
          'repo' => 'Oppulence-Engineering/demo',
          'branch' => 'main',
          'deploy_on_push' => false
        },
        'envs' => [{ 'key' => 'API_KEY', 'type' => 'SECRET', 'value' => 'EV[encrypted]' }]
      }]
    }
    write_spec
  end

  def teardown
    ENV.replace(@old)
    FileUtils.remove_entry(@dir)
  end

  def write_spec
    File.write(File.join(@dir, 'app.yaml'), YAML.dump(@spec))
  end

  def validate
    policy = AppPlatform.validate_options
    AppPlatform.validate_build_paths(@dir)
    AppPlatform.validate_spec(AppPlatform.spec(@dir), policy: policy,
                              require_digests: AppPlatform.boolean('REQUIRE_IMAGE_DIGESTS'),
                              repository: ENV.fetch('GITHUB_REPOSITORY'),
                              ref: ENV.fetch('DEPLOY_REF'),
                              build_image: AppPlatform.boolean('BUILD_IMAGE'))
  end

  def set_image_build
    ENV['BUILD_IMAGE'] = 'true'
    File.write(File.join(@dir, 'Dockerfile'), 'FROM scratch')
    @spec['services'][0].delete('github')
    @spec['services'][0]['image'] = {
      'registry_type' => 'GHCR', 'registry' => 'oppulence-engineering',
      'repository' => 'demo', 'tag' => 'ci-placeholder'
    }
    write_spec
  end

  def app(deployment_id, sha: SHA, phase: 'ACTIVE')
    snapshot = JSON.parse(JSON.generate(@spec))
    {
      'id' => APP_ID,
      'spec' => snapshot,
      'active_deployment' => {
        'id' => deployment_id,
        'phase' => phase,
        'spec' => snapshot,
        'services' => [{ 'name' => 'web', 'source_commit_hash' => sha }]
      },
      'live_url' => 'https://demo.example.com'
    }
  end

  def write_app(name, data)
    path = File.join(@dir, name)
    File.write(path, JSON.generate([data]))
    path
  end

  def test_valid_source_and_new_active_deployment
    validate
    before = write_app('before.json', app('old'))
    after = write_app('after.json', app('new'))
    AppPlatform.preflight(@dir, before)
    AppPlatform.verify(@dir, before, after)
    assert_includes File.read(ENV.fetch('GITHUB_OUTPUT')), 'deployment_id=new'
  end

  def test_rejects_moved_branch_in_spec
    @spec['services'][0]['github']['branch'] = 'other'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
  end

  def test_rejects_auto_deploy_and_plaintext_secret
    @spec['services'][0]['github']['deploy_on_push'] = true
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    @spec['services'][0]['github']['deploy_on_push'] = false
    @spec['services'][0]['envs'][0]['value'] = 'plaintext'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    @spec['services'][0]['envs'][0]['type'] = 'secret'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
  end

  def test_infisical_references_require_scoped_oidc_configuration
    @spec['services'][0]['envs'][0]['value'] = 'infisical://DATABASE_URL'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    ENV['INFISICAL_IDENTITY_ID'] = APP_ID
    assert_raises(AppPlatform::Error) { AppPlatform.validate_options }
    ENV['INFISICAL_PROJECT_ID'] = APP_ID
    ENV['INFISICAL_SECRET_PATH'] = '/screenshot-studio'
    validate
    ENV['INFISICAL_SECRET_PATH'] = '/../other'
    assert_raises(AppPlatform::Error) { AppPlatform.validate_options }
  end

  def test_resolves_infisical_secret_without_echoing_it
    ENV['INFISICAL_IDENTITY_ID'] = APP_ID
    ENV['INFISICAL_PROJECT_ID'] = APP_ID
    ENV['DATABASE_URL'] = 'postgresql://test:private@example.test/db'
    @spec['services'][0]['envs'][0]['value'] = 'infisical://DATABASE_URL'
    write_spec
    validate
    AppPlatform.render_secrets(@dir)
    assert_equal ENV.fetch('DATABASE_URL'), AppPlatform.spec(@dir)['services'][0]['envs'][0]['value']
    assert_equal 0o600, File.stat(File.join(@dir, 'app.yaml')).mode & 0o777
  end

  def test_fails_closed_when_infisical_secret_is_missing
    ENV['INFISICAL_IDENTITY_ID'] = APP_ID
    ENV['INFISICAL_PROJECT_ID'] = APP_ID
    ENV.delete('MISSING_DEPLOY_SECRET')
    @spec['services'][0]['envs'][0]['value'] = 'infisical://MISSING_DEPLOY_SECRET'
    write_spec
    assert_raises(AppPlatform::Error) { AppPlatform.render_secrets(@dir) }
    assert_equal 'infisical://MISSING_DEPLOY_SECRET', AppPlatform.spec(@dir)['services'][0]['envs'][0]['value']
  end

  def test_accepts_component_bindable_secret_and_valid_git_ref
    @spec['services'][0]['envs'][0]['value'] = '${postgres-db.PASSWORD}'
    @spec['services'][0]['github']['branch'] = 'release+signed'
    ENV['DEPLOY_REF'] = 'refs/heads/release+signed'
    write_spec
    validate
  end

  def test_rejects_mutable_image_without_opt_out
    @spec['services'][0].delete('github')
    @spec['services'][0]['image'] = { 'repository' => 'demo', 'tag' => 'latest' }
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    ENV['REQUIRE_IMAGE_DIGESTS'] = 'false'
    validate
  end

  def test_renders_all_components_to_one_immutable_image
    set_image_build
    @spec['workers'] = [{ 'name' => 'worker', 'image' => @spec['services'][0]['image'].dup }]
    write_spec
    validate
    ENV['IMAGE_DIGEST'] = "sha256:#{'b' * 64}"
    AppPlatform.render_image(@dir)
    rendered = AppPlatform.spec(@dir)
    assert_equal 2, AppPlatform.components(rendered).length
    AppPlatform.components(rendered).each do |_kind, entry|
      assert_equal ENV.fetch('IMAGE_DIGEST'), entry.dig('image', 'digest')
      refute entry['image'].key?('tag')
    end
    ENV['BUILD_IMAGE'] = 'false'
    validate
  end

  def test_preserves_prebuilt_component_digest_while_rendering_built_image
    set_image_build
    fixed_digest = "sha256:#{'c' * 64}"
    @spec['services'] << {
      'name' => 'storage',
      'image' => { 'registry_type' => 'DOCKER_HUB', 'repository' => 'supabase/storage-api',
                   'digest' => fixed_digest }
    }
    write_spec
    validate
    ENV['IMAGE_DIGEST'] = "sha256:#{'b' * 64}"
    AppPlatform.render_image(@dir)
    rendered = AppPlatform.spec(@dir)
    assert_equal ENV.fetch('IMAGE_DIGEST'), rendered['services'][0].dig('image', 'digest')
    assert_equal fixed_digest, rendered['services'][1].dig('image', 'digest')
    @spec = rendered
    @spec['services'][1]['image'].delete('repository')
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    @spec['services'][1]['image']['repository'] = 'supabase/storage-api'
    write_spec
    ENV['BUILD_IMAGE'] = 'false'
    validate
  end

  def test_rejects_unrelated_image_or_missing_build_file
    set_image_build
    @spec['services'][0]['image']['repository'] = 'unrelated'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    @spec['services'][0]['image']['tag'] = 'latest'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    @spec['services'][0]['image']['repository'] = 'demo'
    @spec['services'][0]['image']['tag'] = 'ci-placeholder'
    write_spec
    ENV['DOCKERFILE_PATH'] = '../Dockerfile'
    assert_raises(AppPlatform::Error) { validate }
    ENV['DOCKERFILE_PATH'] = 'Dockerfile'
    @spec['workers'] = [{ 'name' => 'other', 'github' => @spec['services'][0]['github'] || {} }]
    write_spec
    assert_raises(AppPlatform::Error) { validate }
  end

  def test_verifies_image_digest_and_rejects_registry_credentials
    digest = "sha256:#{'a' * 64}"
    @spec['services'][0].delete('github')
    @spec['services'][0]['image'] = { 'repository' => 'demo', 'digest' => digest }
    write_spec
    validate
    before = write_app('before.json', app('old'))
    after_app = app('new')
    after_app['active_deployment']['spec']['services'][0]['image']['digest'] = "sha256:#{'b' * 64}"
    assert_raises(AppPlatform::Error) do
      AppPlatform.verify(@dir, before, write_app('wrong-image.json', after_app))
    end
    @spec['services'][0]['image']['registry_credentials'] = 'user:token'
    write_spec
    assert_raises(AppPlatform::Error) { validate }
  end

  def test_off_policy_allows_external_source
    @spec['services'][0].delete('github')
    @spec['services'][0]['gitlab'] = { 'repo' => 'other/demo', 'branch' => 'main',
                                       'deploy_on_push' => false }
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    ENV['SOURCE_REVISION_POLICY'] = 'off'
    validate
    @spec['services'][0]['gitlab']['deploy_on_push'] = true
    write_spec
    assert_raises(AppPlatform::Error) { validate }
  end

  def test_rejects_image_auto_deploy
    @spec['services'][0].delete('github')
    @spec['services'][0]['image'] = {
      'repository' => 'demo',
      'digest' => "sha256:#{'a' * 64}",
      'deploy_on_push' => { 'enabled' => true }
    }
    write_spec
    assert_raises(AppPlatform::Error) { validate }
  end

  def test_rejects_spec_escape_and_invalid_options
    File.symlink('/etc/hosts', File.join(@dir, 'escape.yaml'))
    ENV['APP_SPEC_PATH'] = 'escape.yaml'
    assert_raises(AppPlatform::Error) { AppPlatform.spec(@dir) }
    ENV['APP_SPEC_PATH'] = 'app.yaml'
    ENV['DEPLOY_TIMEOUT_MINUTES'] = '999'
    assert_raises(AppPlatform::Error) { AppPlatform.validate_options }
    ENV['DEPLOY_TIMEOUT_MINUTES'] = '60'
    ENV['DEPLOY_REF'] = 'refs/heads/release..bad'
    assert_raises(AppPlatform::Error) { AppPlatform.validate_options }
  end

  def test_rejects_wrong_app_and_busy_app
    wrong = app('old')
    wrong['spec']['name'] = 'another-app'
    assert_raises(AppPlatform::Error) { AppPlatform.preflight(@dir, write_app('wrong.json', wrong)) }
    busy = app('old')
    busy['in_progress_deployment'] = { 'phase' => 'BUILDING' }
    assert_raises(AppPlatform::Error) { AppPlatform.preflight(@dir, write_app('busy.json', busy)) }
  end

  def test_rejects_old_or_failed_or_wrong_commit_deployment
    before = write_app('before.json', app('old'))
    assert_raises(AppPlatform::Error) { AppPlatform.verify(@dir, before, write_app('same.json', app('old'))) }
    assert_raises(AppPlatform::Error) do
      AppPlatform.verify(@dir, before, write_app('failed.json', app('new', phase: 'ERROR')))
    end
    assert_raises(AppPlatform::Error) do
      AppPlatform.verify(@dir, before, write_app('wrong-sha.json', app('new', sha: 'b' * 40)))
    end
    malformed = app('new')
    malformed['active_deployment']['services'] = { 'name' => 'web' }
    assert_raises(AppPlatform::Error) do
      AppPlatform.verify(@dir, before, write_app('malformed.json', malformed))
    end
  end

  def test_https_health_url_only
    assert_raises(AppPlatform::Error) { AppPlatform.validate_health_url('http://example.com/health') }
    assert_raises(AppPlatform::Error) { AppPlatform.validate_health_url('https://user:pass@example.com') }
    assert_instance_of URI::HTTPS, AppPlatform.validate_health_url('https://example.com/health')
  end
end
