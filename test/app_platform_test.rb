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
      'GITHUB_REPOSITORY' => 'Oppulence-Engineering/demo',
      'GITHUB_SHA' => SHA,
      'HEALTHCHECK_URL' => '',
      'HEALTHCHECK_ATTEMPTS' => '12',
      'HEALTHCHECK_INTERVAL_SECONDS' => '5',
      'HEALTHCHECK_TIMEOUT_SECONDS' => '10',
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
    AppPlatform.validate_spec(AppPlatform.spec(@dir), policy: policy,
                              require_digests: AppPlatform.boolean('REQUIRE_IMAGE_DIGESTS'),
                              repository: ENV.fetch('GITHUB_REPOSITORY'),
                              ref: ENV.fetch('DEPLOY_REF'))
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
    @spec['services'][0]['gitlab'] = { 'repo' => 'other/demo', 'branch' => 'main' }
    write_spec
    assert_raises(AppPlatform::Error) { validate }
    ENV['SOURCE_REVISION_POLICY'] = 'off'
    validate
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
