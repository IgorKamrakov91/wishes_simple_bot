{
  ru: {
    i18n: {
      plural: {
        keys: %i[one few many other],
        rule: lambda do |n|
          return :other unless n.is_a?(Integer)

          mod10 = n % 10
          mod100 = n % 100
          if mod10 == 1 && mod100 != 11 then :one
          elsif (2..4).cover?(mod10) && !(12..14).cover?(mod100) then :few
          else :many
          end
        end
      }
    }
  }
}
