module Hem
  module Lib
    class SelfSignedCertGenerator
      def self.generate domain
        require 'openssl'
        key = OpenSSL::PKey::RSA.new(2048)
        public_key = key.public_key

        subject = "/C=UK/ST=/O=Inviqa/localityName=London/commonName=*.#{domain}/organizationalUnitName=/emailAddress=support@inviqa.com"

        cert = OpenSSL::X509::Certificate.new
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse(subject)
        cert.not_before = Time.now
        cert.not_after = Time.now + 365 * 24 * 60 * 60
        cert.public_key = public_key
        cert.serial = 0x0
        cert.version = 2

        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate = cert
        cert.extensions = [
          ef.create_extension("basicConstraints","CA:TRUE", true),
          ef.create_extension("subjectKeyIdentifier", "hash")
        ]

        cert.add_extension ef.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always")

        cert.sign key, OpenSSL::Digest::SHA1.new

        {
          :key => key.to_pem.to_s.strip,
          :cert => cert.to_pem.to_s.strip
        }
      end
    end
  end
end
