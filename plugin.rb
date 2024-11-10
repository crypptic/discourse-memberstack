# frozen_string_literal: true

# plugin.rb
# name: discourse-memberstack
# about: Validates Memberstack plans during authentication and customizes usernames
# version: 0.0.1
# authors: Your Name
# url: https://github.com/yourusername/discourse-memberstack

enabled_site_setting :memberstack_auth_enabled

require 'net/http'
require 'uri'
require 'json'

after_initialize do
  module ::MemberstackAuth
    module OpenIDConnectAuthenticatorExtension
      def after_authenticate(auth_result)
        # Call the original `after_authenticate` method first
        result = super(auth_result)

        return result unless SiteSetting.memberstack_auth_enabled

        memberstack_id = auth_result.extra_data[:uid]

        unless has_active_plan?(memberstack_id)
          result.failed = true
          result.failed_reason = I18n.t("memberstack_auth.no_active_plan")
          return result
        end

        if result.user.nil? && result.email.present?
          name = auth_result.extra_data[:name].presence
          if name.present?
            username = name.downcase.gsub(/[^a-z0-9]/, '')
            username = UserNameSuggester.suggest(username)
            result.username = username
          end
        end

        result
      end

      private

      def has_active_plan?(member_id)
        return false if member_id.blank?

        uri = URI("https://api.memberstack.io/v2/members/#{member_id}/plans")
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{SiteSetting.memberstack_api_key}"
        request["Content-Type"] = "application/json"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.read_timeout = 10
          http.open_timeout = 10
          http.request(request)
        end

        if response.is_a?(Net::HTTPSuccess)
          member_data = JSON.parse(response.body)
          return member_data["plans"]&.any? { |plan| plan["status"] == "active" } || false
        end

        false
      end
    end
  end

  # Prepend the mixin if OpenIDConnectAuthenticator is defined
  if defined?(OpenIDConnectAuthenticator)
    OpenIDConnectAuthenticator.prepend MemberstackAuth::OpenIDConnectAuthenticatorExtension
  else
    Rails.logger.warn("OpenID Connect authenticator is not available.")
  end
end