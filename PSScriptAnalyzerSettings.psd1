@{
    # CI gates on Error-severity findings only.
    Severity = @('Error')

    ExcludeRules = @(
        # Intentional and unavoidable: random SA password generation (New-sqmRandomSaPassword),
        # certificate import (Install-sqmCertificateToStore) and TSM password handling
        # (Get-sqmTsmConfiguration) must build a SecureString from a generated/looked-up plaintext.
        # There is no encrypted-standard-string source for these by design.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
