import Foundation

/// Builds every `aws` command the bootstrapper runs. Pure: nothing here
/// touches AWS, so each command can be checked in a test.
public struct AWS: Equatable {
    public var profile: String?
    public var region: String?

    public init(profile: String? = nil, region: String? = nil) {
        self.profile = profile
        self.region = region
    }

    public static let managedTag = "psyduck:managed"
    public static let hostTag = "psyduck:host"
    /// The role and instance profile every host gets.
    public static let hostRole = "psyduck-host"
    public static let ssmPolicyARN = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

    /// `aws <args>` plus `--profile` and `--region`, when set.
    func command(_ arguments: [String]) -> Command {
        var all = arguments
        if let profile { all += ["--profile", profile] }
        if let region { all += ["--region", region] }
        return Command("aws", all)
    }

    // MARK: Preflight

    public func callerIdentity() -> Command {
        command(["sts", "get-caller-identity", "--query", "Account", "--output", "text"])
    }

    /// The region the profile would use when `--region` isn't given.
    public func configuredRegion() -> Command {
        command(["configure", "get", "region"])
    }

    // MARK: AMI

    /// Canonical's public SSM parameter for the current Ubuntu 24.04 AMI.
    public static func amiParameter(arch: Architecture) -> String {
        "/aws/service/canonical/ubuntu/server/24.04/stable/current/\(arch.rawValue)/hvm/ebs-gp3/ami-id"
    }

    public func ami(arch: Architecture) -> Command {
        command(["ssm", "get-parameter", "--name", Self.amiParameter(arch: arch),
                 "--query", "Parameter.Value", "--output", "text"])
    }

    // MARK: Key pair

    public func findKeyPair(_ name: String) -> Command {
        command(["ec2", "describe-key-pairs", "--filters", "Name=key-name,Values=\(name)",
                 "--query", "KeyPairs[0].KeyName", "--output", "text"])
    }

    public func importKeyPair(_ name: String, publicKeyPath: String) -> Command {
        command(["ec2", "import-key-pair", "--key-name", name,
                 "--public-key-material", "fileb://\(publicKeyPath)",
                 "--tag-specifications", Self.tagSpecification("key-pair", [(Self.managedTag, "true")])])
    }

    // MARK: IAM (the instance role)

    /// Lets EC2 assume the role. Nothing else may.
    public static let assumeRolePolicy =
        #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}"#

    public func findRole() -> Command {
        command(["iam", "get-role", "--role-name", Self.hostRole,
                 "--query", "Role.RoleName", "--output", "text"])
    }

    public func createRole() -> Command {
        command(["iam", "create-role", "--role-name", Self.hostRole,
                 "--assume-role-policy-document", Self.assumeRolePolicy,
                 "--description", "psyduck hosts: Session Manager access only",
                 "--tags", "Key=\(Self.managedTag),Value=true"])
    }

    /// Attaching an already-attached policy succeeds, so this is safe to repeat.
    public func attachSSMPolicy() -> Command {
        command(["iam", "attach-role-policy", "--role-name", Self.hostRole,
                 "--policy-arn", Self.ssmPolicyARN])
    }

    /// The names of the roles in the instance profile, tab-separated.
    public func findInstanceProfile() -> Command {
        command(["iam", "get-instance-profile", "--instance-profile-name", Self.hostRole,
                 "--query", "InstanceProfile.[InstanceProfileName,Roles[0].RoleName]", "--output", "text"])
    }

    public func createInstanceProfile() -> Command {
        command(["iam", "create-instance-profile", "--instance-profile-name", Self.hostRole,
                 "--tags", "Key=\(Self.managedTag),Value=true"])
    }

    public func addRoleToInstanceProfile() -> Command {
        command(["iam", "add-role-to-instance-profile", "--instance-profile-name", Self.hostRole,
                 "--role-name", Self.hostRole])
    }

    // MARK: Network

    public func defaultVPC() -> Command {
        command(["ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=true",
                 "--query", "Vpcs[0].VpcId", "--output", "text"])
    }

    public static func securityGroupName(_ host: String) -> String { "psyduck-\(host)" }

    public func findSecurityGroup(host: String) -> Command {
        command(["ec2", "describe-security-groups",
                 "--filters", "Name=group-name,Values=\(Self.securityGroupName(host))",
                 "--query", "SecurityGroups[0].GroupId", "--output", "text"])
    }

    /// A new group has no inbound rules and allows all outbound traffic,
    /// which is exactly what a Session Manager host needs.
    public func createSecurityGroup(host: String, vpc: String) -> Command {
        command(["ec2", "create-security-group",
                 "--group-name", Self.securityGroupName(host),
                 "--description", "psyduck host \(host)",
                 "--vpc-id", vpc,
                 "--tag-specifications", Self.tagSpecification("security-group", Self.hostTags(host)),
                 "--query", "GroupId", "--output", "text"])
    }

    public func deleteSecurityGroup(_ id: String) -> Command {
        command(["ec2", "delete-security-group", "--group-id", id])
    }

    /// The CIDRs currently allowed in on port 22, tab-separated.
    public func sshIngress(group: String) -> Command {
        command(["ec2", "describe-security-groups", "--group-ids", group,
                 "--query", "SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp",
                 "--output", "text"])
    }

    public func allowSSH(group: String, cidr: String) -> Command {
        command(["ec2", "authorize-security-group-ingress", "--group-id", group,
                 "--protocol", "tcp", "--port", "22", "--cidr", cidr])
    }

    public func revokeSSH(group: String, cidr: String) -> Command {
        command(["ec2", "revoke-security-group-ingress", "--group-id", group,
                 "--protocol", "tcp", "--port", "22", "--cidr", cidr])
    }

    // MARK: Instances

    /// The live instance for one host, as JSON (see `Instance.parse`).
    public func findInstance(host: String) -> Command {
        describeInstances(filter: "Name=tag:\(Self.hostTag),Values=\(host)")
    }

    /// Every psyduck-managed instance in the region.
    public func listInstances() -> Command {
        describeInstances(filter: "Name=tag:\(Self.managedTag),Values=true")
    }

    private func describeInstances(filter: String) -> Command {
        command(["ec2", "describe-instances", "--filters", filter,
                 "Name=instance-state-name,Values=pending,running,stopping,stopped",
                 "--query", "Reservations[].Instances[].{id:InstanceId,state:State.Name,type:InstanceType,ip:PublicIpAddress,host:Tags[?Key==`\(Self.hostTag)`]|[0].Value}",
                 "--output", "json"])
    }

    public struct Launch: Equatable {
        public var host: String
        public var ami: String
        public var type: String
        public var diskGB: Int
        public var keyPair: String
        public var securityGroup: String
        /// Path of the rendered cloud-init script.
        public var userDataPath: String

        public init(host: String, ami: String, type: String, diskGB: Int, keyPair: String,
                    securityGroup: String, userDataPath: String) {
            self.host = host
            self.ami = ami
            self.type = type
            self.diskGB = diskGB
            self.keyPair = keyPair
            self.securityGroup = securityGroup
            self.userDataPath = userDataPath
        }
    }

    public func runInstance(_ launch: Launch) -> Command {
        // /dev/sda1 is the root device on Canonical's Ubuntu AMIs.
        let disk = #"[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":\#(launch.diskGB),"VolumeType":"gp3","DeleteOnTermination":true}}]"#
        let tags = [("Name", "psyduck-\(launch.host)")] + Self.hostTags(launch.host)
        return command(["ec2", "run-instances",
                        "--image-id", launch.ami,
                        "--instance-type", launch.type,
                        "--count", "1",
                        "--key-name", launch.keyPair,
                        "--iam-instance-profile", "Name=\(Self.hostRole)",
                        "--security-group-ids", launch.securityGroup,
                        "--block-device-mappings", disk,
                        // IMDSv2 only, and one hop: a container on the box
                        // can't reach the instance metadata.
                        "--metadata-options", "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled",
                        // `shutdown` on the box stops the instance; it
                        // never terminates it.
                        "--instance-initiated-shutdown-behavior", "stop",
                        "--tag-specifications",
                        Self.tagSpecification("instance", tags),
                        Self.tagSpecification("volume", tags),
                        "--user-data", "file://\(launch.userDataPath)",
                        "--query", "Instances[0].InstanceId", "--output", "text"])
    }

    public enum Waiter: String {
        case running = "instance-running"
        case stopped = "instance-stopped"
        case terminated = "instance-terminated"
    }

    public func wait(_ waiter: Waiter, instance: String) -> Command {
        command(["ec2", "wait", waiter.rawValue, "--instance-ids", instance])
    }

    /// `Online` once the SSM agent on the instance has registered.
    public func ssmPingStatus(instance: String) -> Command {
        command(["ssm", "describe-instance-information",
                 "--filters", "Key=InstanceIds,Values=\(instance)",
                 "--query", "InstanceInformationList[0].PingStatus", "--output", "text"])
    }

    public func publicIP(instance: String) -> Command {
        command(["ec2", "describe-instances", "--instance-ids", instance,
                 "--query", "Reservations[0].Instances[0].PublicIpAddress", "--output", "text"])
    }

    public func stop(instance: String) -> Command {
        command(["ec2", "stop-instances", "--instance-ids", instance])
    }

    public func start(instance: String) -> Command {
        command(["ec2", "start-instances", "--instance-ids", instance])
    }

    public func terminate(instance: String) -> Command {
        command(["ec2", "terminate-instances", "--instance-ids", instance])
    }

    // MARK: Tags

    static func hostTags(_ host: String) -> [(String, String)] {
        [(managedTag, "true"), (hostTag, host)]
    }

    /// The aws CLI's shorthand: `ResourceType=instance,Tags=[{Key=a,Value=b}]`.
    static func tagSpecification(_ resource: String, _ tags: [(String, String)]) -> String {
        let list = tags.map { "{Key=\($0.0),Value=\($0.1)}" }.joined(separator: ",")
        return "ResourceType=\(resource),Tags=[\(list)]"
    }
}

public enum Architecture: String, CaseIterable, Codable {
    case arm64, amd64
}

/// One row of `describe-instances`, as `AWS.findInstance` and
/// `AWS.listInstances` query it.
public struct Instance: Codable, Equatable {
    public var id: String
    public var state: String
    public var type: String?
    public var ip: String?
    public var host: String?

    public init(id: String, state: String, type: String? = nil, ip: String? = nil, host: String? = nil) {
        self.id = id
        self.state = state
        self.type = type
        self.ip = ip
        self.host = host
    }

    /// Empty output (a dry run) parses as no instances.
    public static func parse(_ json: String) throws -> [Instance] {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        return try JSONDecoder().decode([Instance].self, from: Data(text.utf8))
    }
}
