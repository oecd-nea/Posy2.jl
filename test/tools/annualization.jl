using Posy2
using Test

@testset "Annualization" begin
    # corrected_crf = r/(1+r)/(1-(1+r)^(-n)) for r=0.05, n=20.
    let
        @test isapprox(Posy2.corrected_crf(0.05, 20), 0.0764215116101822; rtol=1e-10)

        # One year profile [1.0] => CF = 1*(1+0.05)^1 = 1.05.
        @test isapprox(Posy2.construction_factor(0.05, 1.0), 1.05; rtol=1e-10)

        # Multi year profile [0.3,0.4,0.3] => 0.3*(1.05)^3 + 0.4*(1.05)^2 + 0.3*(1.05)^1.
        @test isapprox(Posy2.construction_factor(0.05, "0.3;0.4;0.3"), 1.1032875; rtol=1e-10)

        # eac = overnight * construction_factor * corrected_crf.
        @test isapprox(eac(1000.0, 0.05, 20, 1.0), 80.2425871906913; rtol=1e-10)

        # Same eac formula with multi year construction profile.
        @test isapprox(eac(1000.0, 0.05, 20, "0.3;0.4;0.3"), 84.3148984906189; rtol=1e-10)

        # decom_cost = overnight*deco_ratio*(1+r)^(-n)*decommissioning_factor*corrected_crf; profile 1.0 gives factor 1.
        @test isapprox(Posy2.decom_cost(1000.0, 0.1, 25, 0.05, 1.0), 1.99547212373615; rtol=1e-10)
        @test isapprox(Posy2.decom_cost(1000.0, 0.1, 25, 0.05, "1"), 1.99547212373615; rtol=1e-10)

        # Multi year decommissioning profile [0.5, 0.5] after end of lifetime.
        @test isapprox(Posy2.decom_cost(1000.0, 0.1, 25, 0.05, "0.5;0.5"), 1.9479608826948147; rtol=1e-10)

        # Zero discount rate should annualize over lifetime without NaN.
        @test isapprox(Posy2.decom_cost(1000.0, 0.1, 25, 0.0, 1.0), 4.0; rtol=1e-10)
        @test isapprox(Posy2.eac(1000.0, 0.0, 20, 1.0), 50.0; rtol=1e-10)
    end

    # Validation: sum near 1, non negative shares, numeric parse required.
    let
        # Near 1 sum (0.999) should pass and be renormalized to [1/3, 1/3, 1/3].
        @test isapprox(Posy2.construction_factor(0.05, "0.333;0.333;0.333"), 1.103375; rtol=1e-10)

        # decommissioning_factor = sum(share / (1+r)^(year-1)).
        @test isapprox(Posy2.decommissioning_factor(0.05, "0.333;0.333;0.333"), 0.9531368102796673; rtol=1e-10)

        @test_throws ArgumentError Posy2.construction_factor(0.05, "0.2;0.2;0.2")
        @test_throws ArgumentError Posy2.decommissioning_factor(0.05, "0.2;0.2;0.2")

        @test_throws ArgumentError Posy2.construction_factor(0.05, "0.5;-0.2;0.7")
        @test_throws ArgumentError Posy2.decommissioning_factor(0.05, "0.5;-0.2;0.7")

        @test_throws ArgumentError Posy2.construction_factor(0.05, "a;b;c")
        @test_throws ArgumentError Posy2.decommissioning_factor(0.05, "a;b;c")
    end

    # missing construction profile must throw.
    let
        @test_throws ArgumentError eac(1000.0, 0.05, 20, missing)
    end

    # missing decommissioning profile must throw.
    let
        @test_throws ArgumentError Posy2.decommissioning_factor(0.05, missing)
        @test_throws ArgumentError Posy2.decom_cost(1000.0, 0.1, 25, 0.05, missing)
        @test_throws ArgumentError Posy2.decom_cost(1000.0, missing, 25, 0.05, 1.0)
    end
end
