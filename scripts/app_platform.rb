#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'yaml'

module AppPlatform
  class Error < StandardError; end

  COMPONENTS = %w[services static_sites workers jobs functions].freeze
  SOURCE_KEYS = %w[github gitlab bitbucket git image].freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  DIGEST = /\Asha256:[0-9a-f]{64}\z/i
  ENCRYPTED = /\AEV\[[^\]\r\n]+\]\z/
  REFERENCE = /\A\$\{(?:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z0-9_-]+\.[A-Za-z_][A-Za-z0-9_]*)\}\z/

  module_function

  def assert(condition, message)
    raise Error, message unless condition
  end

  def option(name)
    ENV.fetch(name) { raise Error, "Missing #{name}" }
  end

  def integer(name, range)
    value = Integer(option(name), 10)
    assert(range.cover?(value), "#{name} must be between #{range.begin} and #{range.end}")
    value
  rescue ArgumentError
    raise Error, "#{name} must be an integer"
  end

  def boolean(name)
    value = option(name)
    assert(%w[true false].include?(value), "#{name} must be true or false")
    value == 'true'
  end

  def spec(root)
    relative = option('APP_SPEC_PATH')
    assert(!relative.empty? && !relative.start_with?('/') && !relative.split('/').include?('..'),
           'APP_SPEC_PATH must stay inside the caller repository')
    base = File.realpath(root)
    path = File.realpath(File.join(base, relative))
    assert(path.start_with?("#{base}/"), 'APP_SPEC_PATH resolves outside the caller repository')
    assert(File.file?(path), 'APP_SPEC_PATH must point to a file')
    value = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
    assert(value.is_a?(Hash), 'App spec must be a YAML mapping')
    value
  rescue Errno::ENOENT
    raise Error, "App spec not found: #{relative}"
  rescue Psych::Exception => e
    raise Error, "Invalid app spec YAML: #{e.message}"
  end

  def components(data)
    COMPONENTS.flat_map do |kind|
      entries = data.fetch(kind, [])
      assert(entries.is_a?(Array), "#{kind} must be a list")
      entries.map do |entry|
        assert(entry.is_a?(Hash), "Each #{kind} entry must be a mapping")
        [kind, entry]
      end
    end
  end

  def validate_options
    assert(option('APP_ID').match?(UUID), 'APP_ID must be an existing app UUID')
    ref = option('DEPLOY_REF')
    assert((ref.start_with?('refs/heads/') || ref.start_with?('refs/tags/')) &&
           system('git', 'check-ref-format', ref, out: File::NULL, err: File::NULL),
           'DEPLOY_REF must be a full branch or tag ref')
    assert(option('DOCTL_VERSION').match?(/\A\d+\.\d+\.\d+\z/),
           'DOCTL_VERSION must be a pinned semantic version')
    integer('DEPLOY_TIMEOUT_MINUTES', 5..360)
    policy = option('SOURCE_REVISION_POLICY')
    assert(%w[exact branch off].include?(policy), 'SOURCE_REVISION_POLICY must be exact, branch, or off')
    boolean('REQUIRE_IMAGE_DIGESTS')
    integer('HEALTHCHECK_ATTEMPTS', 1..100)
    integer('HEALTHCHECK_INTERVAL_SECONDS', 0..300)
    integer('HEALTHCHECK_TIMEOUT_SECONDS', 1..120)
    url = option('HEALTHCHECK_URL')
    validate_health_url(url) unless url.empty?
    policy
  end

  def validate_health_url(value)
    uri = URI.parse(value)
    assert(uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment,
           'HEALTHCHECK_URL must be an HTTPS URL without credentials or a fragment')
    uri
  rescue URI::InvalidURIError
    raise Error, 'HEALTHCHECK_URL must be a valid HTTPS URL'
  end

  def validate_spec(data, policy:, require_digests:, repository:, ref:)
    name = data['name']
    assert(name.is_a?(String) && !name.strip.empty?, 'App spec must have a name')
    entries = components(data)
    assert(!entries.empty?, 'App spec must contain at least one deployable component')
    expected_branch = ref.delete_prefix('refs/heads/')
    names = []

    entries.each do |kind, entry|
      component_name = entry['name']
      assert(component_name.is_a?(String) && !component_name.empty?, "#{kind} component needs a name")
      assert(!names.include?(component_name), "Duplicate component name: #{component_name}")
      names << component_name
      sources = SOURCE_KEYS.select { |key| entry.key?(key) }
      assert(sources.length == 1, "#{component_name} must have exactly one source")
      source = sources.first
      if policy != 'off'
        assert(%w[github image].include?(source),
               "#{component_name} uses #{source}; set source_revision_policy: off if intentional")
      end
      if source == 'github'
        github = entry['github']
        assert(github.is_a?(Hash), "#{component_name} GitHub source must be a mapping")
        assert(github['deploy_on_push'] == false,
               "#{component_name} must set github.deploy_on_push: false")
        if policy != 'off'
          assert(ref.start_with?('refs/heads/'), 'GitHub source needs a branch deploy_ref')
          assert(github['repo'].to_s.casecmp?(repository),
                 "#{component_name} GitHub repo must match the caller repository")
          assert(github['branch'] == expected_branch,
                 "#{component_name} GitHub branch must match deploy_ref")
        end
      elsif source == 'image' && require_digests
        image = entry['image']
        assert(image.is_a?(Hash) && image['digest'].to_s.match?(DIGEST),
               "#{component_name} must use image.digest: sha256:<64 hex characters>")
        assert(!image.key?('tag'), "#{component_name} must not also set image.tag")
      end
      if source == 'image'
        image = entry['image']
        assert(image.is_a?(Hash), "#{component_name} image source must be a mapping")
        credentials = image['registry_credentials']
        if credentials
          assert(credentials.is_a?(String) && (credentials.match?(ENCRYPTED) || credentials.match?(REFERENCE)),
                 "#{component_name} contains plaintext registry credentials")
        end
      end
      validate_secrets(entry['envs'], "#{component_name} envs")
    end
    validate_secrets(data['envs'], 'app envs')
    name
  end

  def validate_secrets(envs, label)
    return if envs.nil?

    assert(envs.is_a?(Array), "#{label} must be a list")
    envs.each do |env|
      assert(env.is_a?(Hash), "#{label} entries must be mappings")
      next unless env['type'] == 'SECRET'

      value = env['value']
      assert(value.is_a?(String) && (value.match?(ENCRYPTED) || value.match?(REFERENCE)),
             "#{label} contains a plaintext or missing SECRET value")
    end
  end

  def read_app(path)
    body = JSON.parse(File.read(path))
    body = body['app'] if body.is_a?(Hash) && body.key?('app')
    body = body.first if body.is_a?(Array) && body.length == 1
    assert(body.is_a?(Hash), 'Expected one app from doctl apps get -o json')
    body
  rescue JSON::ParserError
    raise Error, 'doctl returned invalid app JSON'
  end

  def check_identity(app, app_id, app_name)
    assert(app['id'].to_s.casecmp?(app_id), 'DigitalOcean returned a different app ID')
    assert(app.dig('spec', 'name') == app_name, 'App spec name differs from the existing app name')
  end

  def check_idle(app)
    pending = app['in_progress_deployment']
    return if pending.nil? || pending == {}

    phase = pending['phase']
    assert(%w[ACTIVE ERROR CANCELED SUPERSEDED].include?(phase),
           "Another deployment is in progress (#{phase || 'unknown phase'})")
  end

  def deployed_component(container, kind, name)
    list = container[kind] || []
    assert(list.is_a?(Array), "DigitalOcean returned malformed #{kind} deployment data")
    list.find { |item| item.is_a?(Hash) && item['name'] == name }
  end

  def preflight(root, before_path)
    data = spec(root)
    app = read_app(before_path)
    check_identity(app, option('APP_ID'), data['name'])
    check_idle(app)
    puts "Verified existing app #{data['name']} (#{option('APP_ID')})"
  end

  def verify(root, before_path, after_path)
    data = spec(root)
    before = read_app(before_path)
    after = read_app(after_path)
    app_id = option('APP_ID')
    check_identity(before, app_id, data['name'])
    check_identity(after, app_id, data['name'])
    check_idle(after)
    deployment = after['active_deployment']
    assert(deployment.is_a?(Hash) && deployment['phase'] == 'ACTIVE',
           'App has no ACTIVE deployment after doctl update')
    deployment_id = deployment['id'].to_s
    assert(!deployment_id.empty? && deployment_id != before.dig('active_deployment', 'id').to_s,
           'No new active deployment was created')

    entries = components(data)
    if option('SOURCE_REVISION_POLICY') == 'exact'
      expected_sha = option('GITHUB_SHA')
      assert(expected_sha.match?(/\A[0-9a-f]{40}\z/i), 'GITHUB_SHA must be a 40-character commit')
      entries.each do |kind, component|
        next unless component.key?('github')

        deployed = deployed_component(deployment, kind, component['name'])
        actual = deployed && deployed['source_commit_hash']
        assert(actual.to_s.casecmp?(expected_sha),
               "#{component['name']} deployed #{actual || 'no recorded commit'}, expected #{expected_sha}")
      end
    end

    if option('REQUIRE_IMAGE_DIGESTS') == 'true'
      deployed_spec = deployment['spec'] || after['spec']
      assert(deployed_spec.is_a?(Hash), 'DigitalOcean returned no active app spec')
      entries.each do |kind, component|
        next unless component.key?('image')

        deployed = deployed_component(deployed_spec, kind, component['name'])
        actual = deployed && deployed.dig('image', 'digest')
        assert(actual == component.dig('image', 'digest'),
               "#{component['name']} active image digest differs from the spec")
      end
    end

    url = after['live_url'].to_s
    output = ENV['GITHUB_OUTPUT']
    if output && !output.empty?
      File.open(output, 'a') do |file|
        file.puts "deployment_id=#{deployment_id}"
        file.puts "app_url=#{url}" if url.match?(/\Ahttps:\/\/[^\s]+\z/)
      end
    end
    summary = ENV['GITHUB_STEP_SUMMARY']
    if summary && !summary.empty?
      File.open(summary, 'a') do |file|
        file.puts "### DigitalOcean App Platform deployment"
        file.puts "- App: [#{data['name']}](https://cloud.digitalocean.com/apps/#{app_id})"
        file.puts "- Deployment: `#{deployment_id}`"
        file.puts "- Source policy: `#{option('SOURCE_REVISION_POLICY')}`"
      end
    end
    puts "Verified active deployment #{deployment_id}"
  end

  def healthcheck
    uri = validate_health_url(option('HEALTHCHECK_URL'))
    attempts = integer('HEALTHCHECK_ATTEMPTS', 1..100)
    interval = integer('HEALTHCHECK_INTERVAL_SECONDS', 0..300)
    timeout = integer('HEALTHCHECK_TIMEOUT_SECONDS', 1..120)
    attempts.times do |index|
      begin
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                   open_timeout: timeout, read_timeout: timeout) do |http|
          http.get(uri.request_uri)
        end
        if response.is_a?(Net::HTTPSuccess)
          puts "Health check succeeded (HTTP #{response.code})"
          return
        end
        warn "Health check attempt #{index + 1}/#{attempts}: HTTP #{response.code}"
      rescue StandardError => e
        warn "Health check attempt #{index + 1}/#{attempts}: #{e.class}"
      end
      sleep interval if index + 1 < attempts
    end
    raise Error, "Health check failed after #{attempts} attempts"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV.shift
    when 'validate'
      policy = AppPlatform.validate_options
      root = ARGV.fetch(0)
      data = AppPlatform.spec(root)
      AppPlatform.validate_spec(data, policy: policy,
                                require_digests: AppPlatform.boolean('REQUIRE_IMAGE_DIGESTS'),
                                repository: AppPlatform.option('GITHUB_REPOSITORY'),
                                ref: AppPlatform.option('DEPLOY_REF'))
      puts "Validated App Platform spec for #{data['name']}"
    when 'preflight'
      AppPlatform.preflight(ARGV.fetch(0), ARGV.fetch(1))
    when 'verify'
      AppPlatform.verify(ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2))
    when 'healthcheck'
      AppPlatform.healthcheck
    else
      raise AppPlatform::Error, 'Usage: app_platform.rb validate|preflight|verify|healthcheck'
    end
  rescue AppPlatform::Error, IndexError => e
    warn "::error::#{e.message}"
    exit 1
  end
end
