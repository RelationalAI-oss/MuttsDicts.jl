using Test
using MuttsDicts

@testset "config_for_size" begin
    prev_config = MuttsDicts._config_for_size(1)
    while prev_config.next_config_size < 2^48
        c = MuttsDicts._config_for_size(prev_config.next_config_size-1)
        @test "$(c)" == "$(prev_config)"
        new_config = MuttsDicts._config_for_size(prev_config.next_config_size)
        @assert new_config.next_config_size > prev_config.next_config_size
        prev_config = new_config
    end
end

@testset "small_dict" begin
    dict = MuttsDict{Int,Int}()
    for i=1:100
        key = i
        value = i*317
        dict[key] = value
        @test length(dict) == i

        check = Tuple{Int,Int}[]
        for (ki,vi) in dict
            push!(check, (ki,vi))
        end
        sort!(check)
        @test length(check) == i
        for k=1:length(check)
            @test check[k] == (k,k*317)
        end
    end
end

@testset "dict" begin
    dict = MuttsDict{Int,Int}()
    N=2^20
    for i=1:N
        key = i
        value = i*317
        insert!(dict, key, value)
        @test getindex(dict,key) == value
        if (i == 7) || (i == 40) || (i == 120) || (i == 1000) || (mod(i,10000) == 0)
            prev_dict = dict
            dict = branch!(dict)
            @test dict !== prev_dict
            @test branch!(prev_dict) !== dict

            check = Vector{Tuple{Int,Int}}()
            for (k,v) in dict
                push!(check, (k,v))
            end
            @test length(check) == i
            sort!(check)
            for k=1:length(check)
                @test check[k] == (k,k*317)
            end
        end
    end
    for i=1:N
        @test getindex(dict, i) == i*317
    end
end

@testset "deletes" begin
    dict = MuttsDict{Int,Int}()
    N=2^20
    for i=1:N
        insert!(dict,i,i*317)
    end

    dict = branch!(dict)
    for i=1:N
        @test in((i,i*317),dict)
        @test in((i=>i*317),dict)
        delete!(dict,i)
        @test !in((i,i*317),dict)
    end

    empty_dict = MuttsDict{Int,Int}()
    diff = setdiff(dict,empty_dict)
    @test length(diff) == 0
end

@testset "setdiff" begin
    prev_dict = MuttsDict{Int,Int}()
    dict = branch!(prev_dict)
    N=2^20
    check_m = 100
    for i=1:N
        insert!(dict, i, i*317)
        if mod(i,check_m)==0
            diff = setdiff(dict,prev_dict)
            sort!(diff)
            @test length(diff) == check_m
            for k=1:check_m
                pk = i-check_m+k
                @test diff[k] == (pk, pk*317)
                if diff[k] != (pk,pk*317)
                    abort()
                end
            end
            diff2 = setdiff(prev_dict,dict)
            @test length(diff2) == 0
            prev_dict = dict
            dict = branch!(prev_dict)
        end
    end
end
