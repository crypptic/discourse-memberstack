# name: discourse-memberstack
# about: Validates Memberstack plans during authentication and customizes usernames
# version: 0.0.1
# authors: David Lowgren
# url: https://github.com/yourusername/discourse-memberstack

require 'net/http'
require 'uri'
require 'json'

enabled_site_setting :memberstack_auth_enabled

after_initialize do
  module ::MemberstackAuth
    class MemberstackAuthenticatorExtension
      def self.register_middleware(authenticator)
        Rails.logger.warn("MemberstackAuth: Registering middleware...")
        
        authenticator.before_complete do |auth_result|
          Rails.logger.warn("MemberstackAuth: Processing authentication...")
          return auth_result unless SiteSetting.memberstack_auth_enabled
          
          memberstack_id = auth_result.extra_data[:uid]
          Rails.logger.warn("MemberstackAuth: Checking member ID: #{memberstack_id}")
          
          unless has_active_plan?(memberstack_id)
            auth_result.failed = true
            auth_result.failed_reason = I18n.t("memberstack_auth.no_active_plan")
            return auth_result
          end
          
          if auth_result.user.nil? && auth_result.email.present?
            name = auth_result.extra_data[:name].presence
            if name.present?
              username = name.downcase.gsub(/[^a-z0-9]/, '')
              username = UserNameSuggester.suggest(username)
              auth_result.username = username
            end
          end
          
          auth_result
        end
      end
      
      private
      
      def self.has_active_plan?(member_id)
        Rails.logger.warn("MemberstackAuth: Checking plan status for member_id: #{member_id}")
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
          Rails.logger.info("MemberstackAuth: Member plans response: #{member_data.inspect}")
          return member_data["plans"]&.any? { |plan| plan["status"] == "active" } || false
        end
        
        Rails.logger.error("MemberstackAuth: Error response: #{response.body}")
        false
      rescue StandardError => e
        Rails.logger.error("MemberstackAuth: Error checking plan status - #{e.message}")
        false
      end
    end
  end
  
  Auth::OpenIDConnectAuthenticator.class_eval do
    MemberstackAuth::MemberstackAuthenticatorExtension.register_middleware(self)
  end
end